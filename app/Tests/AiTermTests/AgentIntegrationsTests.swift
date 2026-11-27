import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport
@testable import AiTerm

/// What AgentIntegrations hears from, and tells, the workspace it serves.
@MainActor
struct AgentIntegrationsTests {
    private func controller() throws -> (AppController, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(),
                                       harnessHome: root.appendingPathComponent("home"), bundledResourcesURL: nil)
        try controller.workspace.load()
        return (controller, root)
    }

    /// The test process hook reports any CLI launched synchronously by an unmarked test.
    @Test func aScratchControllersNativeSkillReadsStayOnDisk() throws {
        let (controller, root) = try controller()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let manifest = home.appendingPathComponent(".agents/skills/example/SKILL.md")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Example".write(to: manifest, atomically: true, encoding: .utf8)
        let skills = controller.agents.nativeSkills
        #expect(skills.antigravityPlugins(home: home).isEmpty)
        #expect(skills.discover(agent: .pi, projectPath: root.path, home: home).map(\.name) == ["skill:example"])
    }

    /// A CLI installed from Settings is offered by the New Task sheet already open, without a
    /// relaunch: the sheet's model reads the CLIs live, and what draws them redraws.
    @Test func anOpenCreationSheetOffersACLISettingsInstalled() throws {
        let (controller, root) = try controller()
        defer { try? FileManager.default.removeItem(at: root) }
        controller.agents.availableAgents = [.claude]
        let project = Project.make(name: "Repo", path: "/repo", addedAt: Date())
        let model = controller.sheets.makeCreationModel(
            project: project, draft: TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil),
            catalogue: [], jira: nil)
        #expect(model.availableAgents == [.claude])

        #expect(invalidates({ _ = model.availableAgents }, by: { controller.agents.harnessSettingsModel().cliInstalled(.pi) }))
        #expect(model.availableAgents == [.claude, .pi])
    }

    /// Settings' model pickers fall back on the model each agent last ran with, read from the
    /// workspace as it is when asked — tasks created while Settings is retained change the answer.
    @Test func theSettingsModelReadsTheWorkspacesRememberedModels() throws {
        let (controller, root) = try controller()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = controller.agents.harnessSettingsModel()
        #expect(settings.rememberedModels().isEmpty)

        controller.workspace.mutate { $0.lastModelByAgent[.codex] = "gpt-5.6" }
        #expect(settings.rememberedModels() == [.codex: "gpt-5.6"])
    }

    /// The shims read the hook port from a file only a driver's Install writes, so launch writes it
    /// too: an app updated over an install from before they read it would otherwise post to nothing
    /// until someone pressed Repair.
    @Test func theLaunchProbeRecordsTheShimsPort() async throws {
        let (controller, root) = try controller()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        #expect(!ShimPort.isRecorded(AiTermPaths.hookPort, home: home))

        await controller.agents.probeStatusLine()

        #expect(ShimPort.isRecorded(AiTermPaths.hookPort, home: home))
    }

    /// Settings' Install of Claude's driver reaches the footer: the model tells the integrations, which
    /// re-read Claude's settings, and the Claude row stops saying "Usage disconnected".
    @Test func aClaudeInstallFromSettingsFlipsTheFootersUsageRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), resources = root.appendingPathComponent("resources")
        let shim = resources.appendingPathComponent("hooks/claude-statusline-shim.sh")
        try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        let controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(),
                                       harnessHome: home, bundledResourcesURL: resources)
        func claudeNote() -> String? {
            SidebarModel.usageVendorRows(UsageSnapshot.empty, now: Date(), calendar: .current,
                                         claudeStatusLineInstalled: controller.agents.claudeStatusLineInstalled)
                .first { $0.vendor == .claude }?.note
        }
        await controller.agents.refreshStatusLineState()
        #expect(claudeNote() == "Usage disconnected")

        // What the driver's Install does to the file the footer reads.
        let settings = home.appendingPathComponent(".claude/settings.json")
        let model = controller.agents.harnessSettingsModel(service: InstallingService {
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"statusLine":{"type":"command","command":"\#(shim.path)"}}"#.utf8).write(to: settings)
        })
        await model.install(.claude)

        await eventually(describing: "the footer to stop saying the status line is gone") { claudeNote() == "No usage data yet" }
    }
}

extension AgentIntegrationsTests {
    /// Reads of Claude's settings start in order but finish on a pool: one that lands after a
    /// newer one does not take back what the newer one found. Here the first read is held until
    /// the second has been applied, then answers the opposite.
    @Test func aStatusLineReadThatLandsLateDoesNotOverwriteANewerOne() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("resources")
        let shim = resources.appendingPathComponent("hooks/claude-statusline-shim.sh")
        try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        let reads = HeldFirstRead()
        let agents = AgentIntegrations(harnessHome: root.appendingPathComponent("home"), bundledResourcesURL: resources,
                                       locateAgents: { nil }, rememberedModels: { [:] },
                                       statusLineIsInstalled: { _, _ in reads.answer() })

        let late = Task { await agents.refreshStatusLineState() }
        await eventually(describing: "the first read to be held") { reads.firstIsHeld }
        await agents.refreshStatusLineState()
        #expect(agents.claudeStatusLineInstalled == false)
        reads.release()
        await late.value

        #expect(agents.claudeStatusLineInstalled == false, "the earlier read's answer landed last and was not applied")
    }
}

/// Answers `true` to the first read once `release` is called, and `false` at once to every other.
private final class HeldFirstRead: Sendable {
    private let state = Mutex((reads: 0, held: false, released: false))
    var firstIsHeld: Bool { state.withLock { $0.held } }
    func release() { state.withLock { $0.released = true } }

    func answer() -> Bool {
        let first = state.withLock { state in
            state.reads += 1
            if state.reads == 1 { state.held = true }
            return state.reads == 1
        }
        guard first else { return false }
        while !state.withLock({ $0.released }) { Thread.sleep(forTimeInterval: 0.005) }
        return true
    }
}

/// A Settings service whose Install runs `install` and answers with a current, ready card.
private struct InstallingService: HarnessServicing {
    let install: @Sendable () throws -> Void

    private func ready(_ agent: AgentKind) -> HarnessSnapshot {
        .reduce(agent: agent, cliAvailable: true, integrationState: .current,
                models: [AgentModel(id: "m", label: "M", detail: nil, efforts: [], defaultEffort: nil)])
    }

    func probe(_ agent: AgentKind) async -> HarnessSnapshot { ready(agent) }
    func install(_ agent: AgentKind) async throws -> HarnessSnapshot { try install(); return ready(agent) }
    func test(_ snapshot: HarnessSnapshot) async -> HarnessSnapshot { snapshot }
}

extension AgentIntegrationsTests {
    @Test func aProfilePortSeesAgentsDiscoveredAfterItWasCreated() async throws {
        let (controller, root) = try controller()
        defer { try? FileManager.default.removeItem(at: root) }
        let read = controller.agents.operatorProfile
        controller.agents.availableAgents = [.claude]
        let missing = await BackgroundWork.run { read() }
        #expect(!missing.oracle.isOn)
        controller.agents.availableAgents = [.claude, .codex]
        let installed = await BackgroundWork.run { read() }
        #expect(installed.oracle.isOn)
    }
}

extension AgentIntegrationsTests {
    @Test func movedSettingsDriveTheUsageProbeAndDisplayedFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), resources = root.appendingPathComponent("resources")
        let hooks = resources.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let shim = hooks.appendingPathComponent("claude-statusline-shim.sh")
        try Data("#!/bin/sh\n".utf8).write(to: shim)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        let directory = root.appendingPathComponent("Claude Profile")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": shim.path]])
        try data.write(to: directory.appendingPathComponent("settings.json"))
        let agents = AgentIntegrations(harnessHome: home, bundledResourcesURL: resources,
                                       locateAgents: { nil }, rememberedModels: { [:] }, defaults: InterfacePreferences.scratch().defaults,
                                       claudeConfig: ClaudeConfig(directory.path))
        await agents.refreshStatusLineState()
        #expect(agents.claudeStatusLineInstalled)
        #expect(agents.claudeConfigPath == directory.path)
    }
}

extension AgentIntegrationsTests {
    @Test func aSignalLoadsThePluginListOnceForAllProjects() throws {
        let launches = Mutex(0)
        let skills = NativeSkills { _, _, _ in
            launches.withLock { $0 += 1 }
            return #"[{"name":"example","enabled":true,"skills":["plan"]}]"#
        }
        let home = try ScratchFolder.make()
        let found = OperatorSkills.listed(at: [home.path, home.appendingPathComponent("another").path],
                                          home: home, config: ClaudeConfig(), skills: skills)
        #expect(found.map(\.name) == ["example:plan"])
        #expect(launches.withLock { $0 } == 1)
    }

    /// Settings › Operator's `/` lists Claude's skills from the configured folder in the harness home.
    @Test func operatorSettingsListClaudesSkillsFromTheConfiguredFolder() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        for (folder, name) in [(".claude", "wrong-folder"), ("profile", "moved")] {
            let skill = home.appendingPathComponent("\(folder)/skills/\(name)/SKILL.md")
            try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: A skill\n---\nBody\n".write(to: skill, atomically: true, encoding: .utf8)
        }
        let agents = AgentIntegrations(harnessHome: home, bundledResourcesURL: nil, locateAgents: { nil }, rememberedModels: { [:] },
                                       defaults: InterfacePreferences.scratch().defaults, claudeConfig: ClaudeConfig("~/profile"))
        let settings = agents.operatorSettings()
        await settings.load()
        let names = settings.completions.all.map(\.name)
        #expect(names.contains("moved") && !names.contains("wrong-folder"))
    }

    /// What an agent's card gives it, which the Operator's tasks launch with: its card's default in
    /// Settings › Agents, else the model last picked for that agent, else empty — the agent's own.
    @Test func anAgentRunsWithItsCardsDefaultElseTheModelLastPickedElseItsOwn() {
        let defaults = ScratchDefaults.make()
        let none = AgentIntegrations.taskModel(.claude, remembered: [:], defaults: defaults)
        #expect(none.model == "" && none.reasoning == nil)
        let remembered = AgentIntegrations.taskModel(.codex, remembered: [.codex: "gpt-5", .claude: "opus"], defaults: defaults)
        #expect(remembered.model == "gpt-5" && remembered.reasoning == nil)
        ModelSettings.save(ModelPreference(model: "sonnet", reasoning: "high"), for: .claude, defaults: defaults)
        let card = AgentIntegrations.taskModel(.claude, remembered: [.claude: "opus"], defaults: defaults)
        #expect(card.model == "sonnet" && card.reasoning == "high")
        let pi = AgentIntegrations.taskModel(.pi, remembered: [.pi: "openai-codex/gpt-5.6-sol", .claude: "opus"], defaults: defaults)
        #expect(pi.model == "openai-codex/gpt-5.6-sol" && pi.reasoning == nil, "PI's own, never Claude's")
    }
}
