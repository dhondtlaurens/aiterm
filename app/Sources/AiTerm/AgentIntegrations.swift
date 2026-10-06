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
    /// installs, and by tests that need an agent missing.
    var availableAgents: Set<AgentKind> = Set(AgentKind.allCases) {
        didSet { availableAgentsChanged(availableAgents) }
    }
    /// Whether AiTerm's shim is still Claude Code's `statusLine` command. Re-read at every launch
    /// and after every hook repair, never cached in UserDefaults: the shim is the whole Claude
    /// usage feed and anything that edits `~/.claude/settings.json` can take it back out, so the
    /// footer has to be able to say "not installed" instead of promising data that is not coming.
    private(set) var claudeStatusLineInstalled = true
    /// Every agent's model list, kept until its files change: what the creation sheets offer and
    /// what Settings' cards show, read through one catalogue so the two agree, and so a sheet opened
    /// again does not read `~/.claude.json` or launch PI again.
    let catalogue: ModelCatalogue

    /// The model each agent last ran with, from the workspace. Read live by the Settings model,
    /// which outlives any one sheet.
    private let rememberedModels: @MainActor () -> [AgentKind: String]
    /// Hears every change to `availableAgents`, so a creation sheet that is already open offers an
    /// agent Settings has just installed.
    private let availableAgentsChanged: @MainActor (Set<AgentKind>) -> Void
    private let harnessHome: URL
    /// What the drivers install from the bundle, looked up once: the Settings service installs
    /// them, and the footer's probe asks whether Claude Code still runs this bundle's shim.
    private let resources: HarnessResources
    /// Which agent CLIs the login shell finds, nil when it could not tell.
    private let locateAgents: @Sendable () -> Set<AgentKind>?
    @ObservationIgnored private var retainedHarnessSettings: HarnessSettingsModel?

    init(harnessHome: URL, bundledResourcesURL: URL?, locateAgents: @escaping @Sendable () -> Set<AgentKind>?,
         rememberedModels: @escaping @MainActor () -> [AgentKind: String],
         availableAgentsChanged: @escaping @MainActor (Set<AgentKind>) -> Void) {
        self.harnessHome = harnessHome
        resources = .bundled(resourceURL: bundledResourcesURL)
        catalogue = ModelCatalogue(home: harnessHome, runner: .live)
        self.locateAgents = locateAgents
        self.rememberedModels = rememberedModels
        self.availableAgentsChanged = availableAgentsChanged
    }

    /// Claude Code's status-line shim in the bundle, if it is there and can be run. Bundle lookups
    /// are optional because `swift run`, damaged copies and translocated apps do not necessarily
    /// contain installable resources. Settings reports that state instead of persisting a path
    /// that cannot work after launch.
    var shimURL: URL? { resources[.claude].map(URL.init(fileURLWithPath:)) }

    /// The launch probes, together: the CLI lookup is a login shell costing the better part of a
    /// second, and the status line is a read of Claude's settings that need not wait for it.
    func probe() async {
        let locate = locateAgents
        async let agents = try? BackgroundWork.run { locate() }
        async let statusLine: Void = probeStatusLine()
        let (installed, _) = await (agents, statusLine)
        guard !Task.isCancelled else { return }
        // Unknown when the login shell failed: every agent stays offered rather than none.
        if let installed = installed ?? nil { availableAgents = installed }
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
        let shim = resources[.claude], home = harnessHome
        let installed = try? await BackgroundWork.run {
            if migrating {
                do { try StatusLineOriginal.migrate(home: home) }
                catch { NSLog("AiTerm: could not migrate the saved status line: \(error.localizedDescription)") }
                // The shims are in the bundle and so are as new as the app, but read the port from a
                // file only a driver's Install writes: until it has, an upgrade's status line posts
                // to nothing and the footer's usage goes quiet.
                do { try ShimPort.record(AiTermPaths.hookPort, home: home) }
                catch { NSLog("AiTerm: could not record the hook port: \(error.localizedDescription)") }
            }
            // The harness home this was given, never the default: in a test that is a temporary
            // directory, and the developer's own `~/.claude` says nothing about it.
            return shim.map { ClaudeSettings.statusLineIsInstalled(home: home, shimPath: $0) } ?? false
        }
        guard !Task.isCancelled else { return }
        claudeStatusLineInstalled = installed ?? false
    }

    /// Retained across Settings presentations, and its service with it, so the last-known-good PI
    /// catalogue survives a transient discovery failure and SwiftUI recomposing the sheet root does
    /// not probe again. The remembered models are read live for the same reason: it outlives a sheet.
    func harnessSettingsModel() -> HarnessSettingsModel {
        if let retainedHarnessSettings { return retainedHarnessSettings }
        let service = HarnessService(
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
