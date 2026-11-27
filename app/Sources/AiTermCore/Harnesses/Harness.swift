import Foundation

/// Everything AiTerm knows about one agent's harness that is not its driver's own business: the
/// CLI and how it is installed, how tasks and headless requests launch it, its reasoning levels and where its model
/// list comes from, where its skills live, and the driver that reports its state. One value per
/// agent (`Harness+Agents.swift`), reached through `AgentKind.harness` — the one switch over the
/// agents — so a vendor's change, or a fifth harness, is an edit in one place rather than a hunt
/// through a switch in every file that needs a fact.
public struct Harness: Sendable {
    public let agent: AgentKind
    /// The CLI's name on the login shell's `PATH`.
    public let executable: String
    public let displayName: String
    /// How far AiTerm supports the agent (`SupportTier`); the daemon's harness row says the same.
    public let support: SupportTier
    /// Whether the delivery check drives the CLI: AiTerm reads its screen (the daemon's harness row has
    /// an input-box marker). A pass for its version is what lets an agent have full support.
    public let messagingChecked: Bool
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
    /// CLI arguments for listing installed skills when the harness supports discovery.
    var skillListArguments: [String]? = nil
    /// The daemon's path for this agent's events, which a driver's Test posts to.
    let hookEndpoint: String
    /// What the driver installs from the app bundle, when it installs anything from there.
    let bundledResource: BundledResource?
    /// What goes right before a launch prompt, when the CLI takes one only after a flag: Antigravity's
    /// `-i`, without which the prompt lands in its input unsent.
    let promptFlag: [String]
    /// The launch command's arguments after the CLI and before the prompt, unquoted.
    let launchArguments: @Sendable (_ model: String, _ reasoning: String?) -> [String]
    /// The model and reasoning words, unquoted.
    let modelArguments: @Sendable (_ model: String, _ reasoning: String?) -> [String]
    /// A review tab's read-only arguments, when the CLI offers them.
    let readOnlyLaunchArguments: (@Sendable (_ model: String, _ reasoning: String?) -> [String])?
    /// A single read-only answer, with an empty model left to the CLI.
    let readOnlyHeadless: @Sendable (_ prompt: String, _ folder: String, _ readable: [String], _ answerFile: String,
                                   _ model: String, _ reasoning: String?) -> [String]
    let readsAnswerFromFile: Bool
    let headlessAnswer: @Sendable (_ stdout: String, _ answerFile: String?) -> String?
    /// The arguments after the CLI that resume conversation `id` — the one the agent's own hooks name
    /// (`SessionInfo.conversationId`) — as the CLI's `--help` spells them, unquoted.
    let resumeArguments: @Sendable (_ conversation: String) -> [String]
    let models: ModelListing
    /// Where the agent keeps skills and commands, globally and in the project, in the order the
    /// CLI reads them: the first of a name wins.
    let skillRoots: @Sendable (_ home: URL, _ project: URL?) -> [SkillRoot]
    /// The driver, given the daemon's hook port and the bundled resource it installs
    /// (`HarnessResources`); `nil` without one it needs.
    let makeDriver: @Sendable (_ home: URL, _ daemonPort: Int, _ resource: String?) -> (any HarnessDriver)?

    /// The CLI’s model and reasoning flag spellings, shared by interactive and headless runs.
    func modelArguments(model: String, reasoning: String?) -> [String] {
        modelArguments(model, reasoning)
    }

    func hookURL(port: Int) -> String { "http://127.0.0.1:\(port)" + hookEndpoint }

    /// The launch command's words before its prompt, unquoted (`AgentCommand` quotes them).
    func launchWords(model: String, reasoning: String?) -> [String] {
        [executable] + launchArguments(model, reasoning)
    }

    /// A read-only launch's words before its prompt, when the CLI offers one.
    func readOnlyLaunchWords(model: String, reasoning: String?) -> [String]? {
        readOnlyLaunchArguments.map { [executable] + $0(model, reasoning) }
    }

    /// One read-only headless request, carrying an answer file only when the CLI writes its answer there.
    func readOnlyHeadless(prompt: String, folder: String, readable: [String], answerFile: String,
                          model: String, reasoning: String?) -> HeadlessInvocation {
        HeadlessInvocation(executable: executable,
                           arguments: readOnlyHeadless(prompt, folder, readable, answerFile, model, reasoning),
                           answerFile: readsAnswerFromFile ? answerFile : nil)
    }

    /// The resume command's words, unquoted (`AgentCommand` quotes them): the CLI, the conversation,
    /// then the model and reasoning it was launched with, when those are known.
    func resumeWords(conversation: String, model: String?, reasoning: String?) -> [String] {
        [executable] + resumeArguments(conversation) + (model.map { launchArguments($0, reasoning) } ?? [])
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

/// How far AiTerm supports an agent, as `docs/configuration.md` tells the person.
///
/// - `basic`: tasks and tabs launch and resume; models, reasoning and skills are offered; the row's
///   state comes from the agent's own hooks or events; the context ring fills; it can be the Oracle;
///   Settings installs, repairs and tests its driver; the compatibility check captures it.
/// - `full`: basic, and the row's state is checked against a tick (needs-input included), AiTerm
///   types into it once the delivery check passed, and the Operator can give it a task as a worker:
///   choose it, guard its branch and read its replies from its transcript.
///
/// Account usage and background work show where an agent reports them; neither is a tier's.
public enum SupportTier: String, Sendable {
    case basic, full
}

public extension AgentKind {
    /// The agents with full support, in `allCases` order: the Operator's workers and the delivery
    /// check's CLIs.
    static var fullSupport: [AgentKind] { allCases.filter { $0.harness.support == .full } }

    /// The agents the delivery check covers, in `allCases` order: every full one, and any on its way.
    static var messagingChecked: [AgentKind] { allCases.filter { $0.harness.messagingChecked } }

    var harness: Harness {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .pi: return .pi
        case .agy: return .agy
        }
    }

    func harness(claudeConfig: ClaudeConfig) -> Harness { self == .claude ? .claude(config: claudeConfig) : harness }

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

    /// `agent`'s list, read now. A launched list without its CLI is unavailable; a launch's failure
    /// is a `ModelListError`, which `ModelCatalogue` words.
    func read(_ agent: AgentKind, home: URL, executable: String?, runner: HarnessCommandRunner) throws -> [AgentModel] {
        switch self {
        case .files(_, let read): return read(home)
        case .launch(_, let list):
            guard let executable else { throw ModelListError.unavailable(agent) }
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
        /// Markdown commands, a subdirectory's namespaced with a colon.
        case commands(namespace: String? = nil)
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
