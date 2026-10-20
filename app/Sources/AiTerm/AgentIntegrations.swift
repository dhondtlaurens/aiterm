import Foundation
import Synchronization
import AiTermCore

/// The agent CLIs and AiTerm's hooks into them, as this machine has them: which CLIs the login
/// shell finds, whether Claude Code still runs AiTerm's usage shim, and the Settings model that
/// installs and repairs both.
@MainActor
@Observable
final class AgentIntegrations {
    /// Spec 8: which agent CLIs are actually on the login shell's `PATH`. Probed once at launch,
    /// and joined by any CLI Settings installs; until the probe answers, every agent is assumed
    /// present so the sheet is never wrongly blocked. Written only by `probe()` and Settings'
    /// installs, and by tests that need an agent missing; the creation sheets read it live.
    var availableAgents: Set<AgentKind> = Set(AgentKind.allCases) {
        didSet { profileAvailability.set(availableAgents) }
    }
    private let profileAvailability = ProfileAgentAvailability()
    /// Whether AiTerm's shim is still Claude Code's `statusLine` command. Re-read at every launch
    /// and after every hook repair, never cached in UserDefaults: the shim is the whole Claude
    /// usage feed and anything that edits `~/.claude/settings.json` can take it back out, so the
    /// footer has to be able to say "not installed" instead of promising data that is not coming.
    private(set) var claudeStatusLineInstalled = true
    /// Reads of Claude's settings start in order but finish on a pool, so a slow earlier read can
    /// land after a later one: only a read newer than the last one applied may assign.
    @ObservationIgnored private var statusLineReadsStarted = 0
    @ObservationIgnored private var statusLineReadsApplied = 0
    /// Every agent's model list, kept until its files change: what the creation sheets offer and
    /// what Settings' cards show, read through one catalogue so the two agree, and so a sheet opened
    /// again does not read `~/.claude.json` or launch PI again.
    let catalogue: ModelCatalogue
    let claudeConfig: ClaudeConfig
    private(set) var claudeConfigPath: String?

    /// Settings › Agents' “Help with problems”, saved on every write.
    var helpWithProblems: HelpWithProblems {
        didSet { if helpWithProblems != oldValue { HelpWithProblems.save(helpWithProblems, defaults: defaults) } }
    }
    /// What every Find a Fix is: Claude, the Operator's agent, while the switch is on and Claude Code is
    /// installed; else Off.
    var fixer: FixerResolution { helpWithProblems.resolve(installed: availableAgents) }

    /// Settings › Operator's profile as these defaults keep it, read as each caller asks: a broadcast
    /// freezes it as it starts, and every Fix runs at its model and reasoning. Off the main actor.
    var operatorProfile: @Sendable () -> OperatorProfile {
        // UserDefaults is thread-safe, though not marked Sendable.
        nonisolated(unsafe) let defaults = defaults
        let catalogue = catalogue, availability = profileAvailability
        return {
            OperatorProfileStore.load(defaults, claudeDefault: OperatorProfileStore.claudeDefault(
                models: (try? catalogue.models(for: .claude)) ?? [], defaults: defaults), installed: availability.get())
        }
    }

    /// Settings › Operator's staged edits, over these defaults and this catalogue: a new one for each
    /// opening of Settings, so Cancel drops it.
    func operatorSettings() -> OperatorSettingsModel {
        let home = harnessHome, claudeConfig = self.claudeConfig
        return .live(defaults: defaults, catalogue: catalogue, installed: { [weak self] in self?.availableAgents ?? [] },
                     skills: { SkillCatalog.discover(agent: $0, projectPath: nil, home: home, claudeConfig: claudeConfig) })
    }

    /// The model and reasoning every Fix runs with: the Operator's (spec §8, §13), whichever agent it is
    /// handed, since the fixer is always the Operator's own, Claude.
    var fixModel: @Sendable (FixerAgent) -> (model: String, reasoning: String?) {
        let profile = operatorProfile
        return { _ in let operating = profile(); return (operating.model, operating.reasoning) }
    }

    /// The model and reasoning an agent's card gives it: its default in Settings › Agents, else the
    /// model last picked for that agent (`remembered`, the workspace's), else empty — the agent's own
    /// default (`FixerLaunch.modelWords`). What the Operator's tasks launch with when it names none;
    /// a Fix runs at the Operator's own (`fixModel`). Read as each run starts, off the main actor.
    nonisolated static func fixerModel(_ agent: FixerAgent, remembered: [AgentKind: String],
                                       defaults: UserDefaults = .standard) -> (model: String, reasoning: String?) {
        ModelSettings.load(for: agent.agent, defaults: defaults).map { ($0.model, $0.reasoning) } ?? (remembered[agent.agent] ?? "", nil)
    }

    /// `fixerModel` over the models remembered as a launch asks for it.
    nonisolated static func fixerModels(remembered: [AgentKind: String]) -> @Sendable (FixerAgent) -> (model: String, reasoning: String?) {
        { fixerModel($0, remembered: remembered) }
    }
    private let defaults: UserDefaults

    /// The model each agent last ran with, from the workspace. Read live by the Settings model,
    /// which outlives any one sheet.
    private let rememberedModels: @MainActor () -> [AgentKind: String]
    private let harnessHome: URL
    private let bundledResourcesURL: URL?
    /// Claude Code's status-line shim in the bundle, looked up once: the footer's probe asks whether
    /// Claude Code still runs it.
    private let claudeShim: String?
    /// What the drivers install from the bundle, for the Settings service: looked up when Settings
    /// first asks, not at launch, which need not wait on reading the PI extension.
    @ObservationIgnored private lazy var resources = HarnessResources.bundled(resourceURL: bundledResourcesURL)
    /// Which agent CLIs the login shell finds, nil when it could not tell.
    private let locateAgents: @Sendable () -> Set<AgentKind>?
    /// Whether Claude Code's settings in a home run a shim at a path: `ClaudeSettings`' answer, which
    /// a test that orders two reads replaces.
    private let statusLineIsInstalled: @Sendable (_ home: URL, _ shimPath: String, _ config: ClaudeConfig) -> Bool
    @ObservationIgnored private var retainedHarnessSettings: HarnessSettingsModel?

    init(harnessHome: URL, bundledResourcesURL: URL?, locateAgents: @escaping @Sendable () -> Set<AgentKind>?,
         rememberedModels: @escaping @MainActor () -> [AgentKind: String],
         statusLineIsInstalled: (@Sendable (_ home: URL, _ shimPath: String) -> Bool)? = nil,
         defaults: UserDefaults = .standard, claudeConfig: ClaudeConfig = ClaudeConfig()) {
        self.defaults = defaults
        self.claudeConfig = claudeConfig
        helpWithProblems = HelpWithProblems.load(defaults: defaults)
        self.harnessHome = harnessHome
        self.bundledResourcesURL = bundledResourcesURL
        claudeShim = HarnessResources.bundled(resourceURL: bundledResourcesURL, for: [.claude])[.claude]
        catalogue = ModelCatalogue(home: harnessHome, runner: .live, claudeConfig: claudeConfig)
        self.locateAgents = locateAgents
        self.rememberedModels = rememberedModels
        self.statusLineIsInstalled = { home, shim, config in
            statusLineIsInstalled?(home, shim) ?? ClaudeSettings.statusLineIsInstalled(home: home, shimPath: shim, claudeConfig: config)
        }
    }

    /// Over a scratch store and no login shell, every agent assumed present: for a Settings sheet or a test that never probes.
    /// Its defaults are named by a path in the temporary folder, which `UserDefaults` takes as the
    /// file to keep the domain in, so nothing lands in `~/Library/Preferences`.
    static func inert(claudeConfigPath: String? = nil) -> AgentIntegrations {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("AiTerm.inert-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let agents = AgentIntegrations(harnessHome: scratch.appendingPathComponent("home"),
                                 bundledResourcesURL: nil, locateAgents: { nil }, rememberedModels: { [:] },
                                 defaults: UserDefaults(suiteName: scratch.appendingPathComponent("defaults").path)!)
        agents.claudeConfigPath = claudeConfigPath
        return agents
    }

    /// Claude Code's status-line shim in the bundle, if it is there and can be run. Bundle lookups
    /// are optional because `swift run`, damaged copies and translocated apps do not necessarily
    /// contain installable resources. Settings reports that state instead of persisting a path
    /// that cannot work after launch.
    var shimURL: URL? { claudeShim.map(URL.init(fileURLWithPath:)) }

    /// The launch probes, together: the CLI lookup is a login shell costing the better part of a
    /// second, and the status line is a read of Claude's settings that need not wait for it.
    func probe() async {
        let locate = locateAgents
        async let agents = BackgroundWork.run { locate() }
        async let statusLine: Void = probeStatusLine()
        let (installed, _) = await (agents, statusLine)
        guard !Task.isCancelled else { return }
        // Unknown when the login shell failed: every agent stays offered rather than none.
        if let installed { availableAgents = installed }
    }

    /// The status line's launch probe: first the upgrade of an old record of the user's own status
    /// line, which the shim would otherwise stop showing, and the port the shims post to, which an
    /// install from before they read it never recorded, then the read.
    /// Internal, not private, for `theLaunchProbeMigratesAnOldStatusLineRecord`.
    func probeStatusLine() async { await readStatusLine(migratingFirst: true) }

    /// Re-reads whether the shim is still Claude Code's status line, after a Claude install, so the
    /// footer stays honest when another tool edits Claude's settings. Internal, not private, for
    /// `theStatusLineProbeReadsTheHarnessHome`.
    func refreshStatusLineState() async { await readStatusLine(migratingFirst: false) }

    /// Off the main actor, both: `settings.json` is the user's file, of any size, and parsing it
    /// must not hold up the app.
    private func readStatusLine(migratingFirst migrating: Bool) async {
        let shim = claudeShim, home = harnessHome, isInstalled = statusLineIsInstalled, config = claudeConfig
        statusLineReadsStarted += 1
        let read = statusLineReadsStarted
        let (installed, directory) = await BackgroundWork.run {
            let directory = config.directory(home: home)
            if migrating {
                Log.harness.attempt("Migrating the saved status line") { try StatusLineOriginal.migrate(home: home) }
                // The shims are in the bundle and so are as new as the app, but read the port from a
                // file only a driver's Install writes: until it has, an upgrade's status line posts
                // to nothing and the footer's usage goes quiet.
                Log.harness.attempt("Recording the hook port") { try ShimPort.record(AiTermPaths.hookPort, home: home) }
            }
            // The harness home this was given, never the default: in a test that is a temporary
            // directory, and the developer's own `~/.claude` says nothing about it.
            return (shim.map { isInstalled(home, $0, config) } ?? false, directory.path)
        }
        guard !Task.isCancelled, read > statusLineReadsApplied else { return }
        statusLineReadsApplied = read
        claudeStatusLineInstalled = installed
        claudeConfigPath = directory
    }

    /// Retained across Settings presentations, and its service with it, so the last-known-good PI
    /// catalogue survives a transient discovery failure and SwiftUI recomposing the sheet root does
    /// not probe again. The remembered models are read live for the same reason: it outlives a sheet.
    ///
    /// `service` stands in for the real one in a test that must not launch a login shell. It is used
    /// by the call that builds the model, the first; a later one is handed the model already built,
    /// with the service it was built with, so passing one then is a mistake.
    func harnessSettingsModel(service: (any HarnessServicing)? = nil) -> HarnessSettingsModel {
        if let retainedHarnessSettings {
            assert(service == nil, "the Settings model is already built, with the service it was given first")
            return retainedHarnessSettings
        }
        let service = service ?? HarnessService(
            home: harnessHome, daemonPort: AiTermPaths.hookPort, catalogue: catalogue, resources: resources, claudeConfig: claudeConfig)
        let settings = HarnessSettingsModel(
            service: service, rememberedModels: { [weak self] in self?.rememberedModels() ?? [:] },
            integrationChanged: { [weak self] agent in
                if agent == .claude { Task { await self?.refreshStatusLineState() } }
            },
            cliInstalled: { [weak self] agent in self?.availableAgents.insert(agent) })
        retainedHarnessSettings = settings
        return settings
    }
}

/// A background profile read sees the latest CLI probe, including after the port was created.
private final class ProfileAgentAvailability: Sendable {
    private let agents = Mutex(Set(AgentKind.allCases))
    func set(_ installed: Set<AgentKind>) { agents.withLock { $0 = installed } }
    func get() -> Set<AgentKind> { agents.withLock { $0 } }
}
