import Foundation

/// Everything AiTerm knows about one agent's harness that is not its driver's own business: the
/// CLI and how it is installed, how a task launches it, its reasoning levels and where its model
/// list comes from, where its skills live, and the driver that reports its state. One value per
/// agent (`Harness+Agents.swift`), reached through `AgentKind.harness` — the one switch over the
/// agents — so a vendor's change, or a fifth harness, is an edit in one place rather than a hunt
/// through a switch in every file that needs a fact.
public struct Harness: Sendable {
    public let agent: AgentKind
    /// The CLI's name on the login shell's `PATH`.
    public let executable: String
    public let displayName: String
    /// The vendor's own installer, which Install runs through the login shell (`CLIInstaller`).
    public let installCommand: String
    /// The reasoning levels offered while no model is picked, and the one picked then.
    let fallbackEfforts: [String]
    let defaultEffort: String
    /// What the harness card and the task sheets say when the agent lists no models: how to get
    /// some, where the CLI has a way.
    public let noModelsExplanation: String
    /// What a picked skill is written with in the prompt; a command is always written with `/`.
    let skillSigil: Character
    /// The daemon's path for this agent's events, which a driver's Test posts to.
    let hookEndpoint: String
    /// What the driver installs from the app bundle, when it installs anything from there.
    let bundledResource: BundledResource?
    /// The launch command's arguments after the CLI and before the prompt, unquoted.
    let launchArguments: @Sendable (_ model: String, _ reasoning: String?) -> [String]
    let models: ModelListing
    /// Where the agent keeps skills and commands, globally and in the project, in the order the
    /// CLI reads them: the first of a name wins.
    let skillRoots: @Sendable (_ home: URL, _ project: URL?) -> [SkillRoot]
    /// The driver, given the daemon's hook port and the bundled resource it installs
    /// (`HarnessResources`); `nil` without one it needs.
    let makeDriver: @Sendable (_ home: URL, _ daemonPort: Int, _ resource: String?) -> (any HarnessDriver)?

    /// The launch command's words before its prompt, unquoted (`AgentCommand` quotes them).
    func launchWords(model: String, reasoning: String?) -> [String] {
        [executable] + launchArguments(model, reasoning)
    }

    /// The reasoning levels for the picked model. The CLIs publish them per model now, so the
    /// agent's own list is only the answer when no model is picked, or when the picked model comes
    /// from a source that carries no levels (the aliases, `availableModels`). A model that
    /// publishes *no* levels — Haiku, whose catalogue entry says `thinking: none` — is not that
    /// case: it genuinely takes no reasoning flag, and returning an empty list says so.
    public func efforts(for model: AgentModel?) -> [String] { model?.efforts ?? fallbackEfforts }

    public func defaultEffort(for model: AgentModel?) -> String? {
        guard let model else { return defaultEffort }
        return model.defaultEffort
    }
}

public extension AgentKind {
    var harness: Harness {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .grok: return .grok
        case .pi: return .pi
        }
    }

    var displayName: String { harness.displayName }
}

/// Where an agent's model list comes from. `sources` are the files it is made from, in a fixed
/// order, which `ModelCatalogue` stamps to know when to read the list again.
enum ModelListing: Sendable {
    /// Read off files in the home, starting nothing.
    case files(sources: @Sendable (_ home: URL) -> [String], read: @Sendable (_ home: URL) -> [AgentModel])
    /// A launch of the CLI, whose answer is made from `sources` and the CLI itself: an upgrade can
    /// change the list too.
    case launch(sources: @Sendable (_ home: URL) -> [String],
                list: @Sendable (_ executable: String, _ runner: HarnessCommandRunner) throws -> [AgentModel])

    var launchesCLI: Bool {
        if case .launch = self { return true }
        return false
    }

    /// What the list is made from; `executable` is the CLI a launched list comes from.
    func sources(home: URL, executable: String?) -> [String] {
        switch self {
        case .files(let sources, _): return sources(home)
        case .launch(let sources, _):
            return sources(home) + (executable.map { [$0, ($0 as NSString).resolvingSymlinksInPath] } ?? [])
        }
    }

    /// The list, read now. A launched list without its CLI is unavailable. PI's is the only one
    /// launched, so a launch's failure is `PiModelCatalogError`, which `ModelCatalogue` words; a
    /// second launched list would generalise that error, not copy it.
    func read(home: URL, executable: String?, runner: HarnessCommandRunner) throws -> [AgentModel] {
        switch self {
        case .files(_, let read): return read(home)
        case .launch(_, let list):
            guard let executable else { throw PiModelCatalogError.unavailable }
            return try list(executable, runner)
        }
    }
}

/// One place an agent keeps skills or commands, and how its CLI reads that place.
struct SkillRoot: Sendable {
    enum Kind: Sendable {
        /// Directories that hold a `SKILL.md`, each name put under `namespace` when there is one.
        /// `hidingNonInvocable` drops a skill whose frontmatter says `user-invocable: false`.
        case skills(namespace: String? = nil, hidingNonInvocable: Bool = false)
        /// Markdown commands, a subdirectory's namespaced with a colon, down to `depth`.
        case commands(namespace: String? = nil, depth: Int = SkillCatalog.maxDepth)
        /// Every installed plugin's skills and commands, under `<url>/plugins`.
        case plugins(hidingNonInvocable: Bool = false)
    }

    /// `source` is what the place's completions are offered as; a plugin's are offered as that
    /// plugin's, whatever it says.
    var kind: Kind, url: URL, source: AgentCompletion.Source

    init(_ kind: Kind, _ url: URL, _ source: AgentCompletion.Source) {
        self.kind = kind; self.url = url; self.source = source
    }
}

/// A file in the app bundle's `hooks` folder that a driver installs.
enum BundledResource: Sendable {
    /// A script the agent runs from the bundle, taken by its path: there only when it can be run.
    case script(String)
    /// A file the driver writes into the agent's home, taken by its contents.
    case source(String)

    func load(fromHooks hooks: URL) -> String? {
        switch self {
        case .script(let name):
            let path = hooks.appendingPathComponent(name).path
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        case .source(let name):
            return try? String(contentsOf: hooks.appendingPathComponent(name), encoding: .utf8)
        }
    }
}
