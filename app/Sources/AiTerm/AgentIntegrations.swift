import Foundation
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
    var availableAgents: Set<AgentKind> = Set(AgentKind.allCases)
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
    private let statusLineIsInstalled: @Sendable (_ home: URL, _ shimPath: String) -> Bool
    @ObservationIgnored private var retainedHarnessSettings: HarnessSettingsModel?

    init(harnessHome: URL, bundledResourcesURL: URL?, locateAgents: @escaping @Sendable () -> Set<AgentKind>?,
         rememberedModels: @escaping @MainActor () -> [AgentKind: String],
         statusLineIsInstalled: @escaping @Sendable (_ home: URL, _ shimPath: String) -> Bool = {
             ClaudeSettings.statusLineIsInstalled(home: $0, shimPath: $1)
         }) {
        self.harnessHome = harnessHome
        self.bundledResourcesURL = bundledResourcesURL
        claudeShim = HarnessResources.bundled(resourceURL: bundledResourcesURL, for: [.claude])[.claude]
        catalogue = ModelCatalogue(home: harnessHome, runner: .live)
        self.locateAgents = locateAgents
        self.rememberedModels = rememberedModels
        self.statusLineIsInstalled = statusLineIsInstalled
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
        let shim = claudeShim, home = harnessHome, isInstalled = statusLineIsInstalled
        statusLineReadsStarted += 1
        let read = statusLineReadsStarted
        let installed = await BackgroundWork.run {
            if migrating {
                Log.harness.attempt("Migrating the saved status line") { try StatusLineOriginal.migrate(home: home) }
                // The shims are in the bundle and so are as new as the app, but read the port from a
                // file only a driver's Install writes: until it has, an upgrade's status line posts
                // to nothing and the footer's usage goes quiet.
                Log.harness.attempt("Recording the hook port") { try ShimPort.record(AiTermPaths.hookPort, home: home) }
            }
            // The harness home this was given, never the default: in a test that is a temporary
            // directory, and the developer's own `~/.claude` says nothing about it.
            return shim.map { isInstalled(home, $0) } ?? false
        }
        guard !Task.isCancelled, read > statusLineReadsApplied else { return }
        statusLineReadsApplied = read
        claudeStatusLineInstalled = installed
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
            home: harnessHome, daemonPort: AiTermPaths.hookPort, catalogue: catalogue, resources: resources)
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
