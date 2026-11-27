import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor @Suite(.blocking) struct SheetPreparationControllerTests {
    enum CatalogueOutcome: CaseIterable { case success, offline, dismiss }
    @Test(arguments: [false, true], CatalogueOutcome.allCases)
    func newAndEditSignalOpenBeforeTheAgyReadEnds(editing: Bool, outcome: CatalogueOutcome) async throws {
        let folder = ScratchFolder.path("signal-presentation-")
        var ports = OperatorPorts.scratch()
        ports.installedAgents = { [.agy] }
        let calls = Mutex(0), release = DispatchSemaphore(value: 0)
        let runner = HarnessCommandRunner(locate: { _ in "/bin/echo" }, run: { _, arguments, _, _ in
            #expect(arguments == ["models"])
            calls.withLock { $0 += 1 }
            _ = release.wait(timeout: .now() + TestDeadline.seconds)
            if outcome == .offline { throw HarnessProcessError.launchFailed("offline") }
            return ProcessOutput(status: 0, stdout: "model-high\tModel (High)", stderr: "", timedOut: false)
        })
        let controller = AppController(store: StateStore(url: folder.appendingPathComponent("state.json")),
                                       preferences: .scratch(), harnessHome: folder, operatorPorts: ports)
        defer { release.signal(); controller.shutdown(); try? FileManager.default.removeItem(at: folder) }
        try controller.workspace.load()
        controller.agents.availableAgents = [.agy]
        let harness = controller.agents.harnessSettingsModel(service: HarnessService(home: folder, daemonPort: 0, runner: runner,
            resources: HarnessResources([:], installationAllowed: false, unavailableReason: nil)))
        var world = SignalWorld()
        let signal = world.signal(agents: [.init(agent: .agy, model: "model", reasoning: "high")])
        controller.presentNewSignal(editing: editing ? world.state.signal(id: signal) : nil)
        guard case .signal(let model) = controller.sheet else { Issue.record("The sheet must open on the first click"); return }
        let checking = Task { await model.checkReadiness() }
        defer { checking.cancel() }
        #expect(await eventually { calls.withLock { $0 } == 1 })
        controller.presentNewSignal()
        guard case .signal(let same) = controller.sheet else { Issue.record("Lost the open sheet"); return }
        #expect(model === same)
        let row = try #require(model.agentRows.first)
        model.name = "Typed while loading"
        if !editing { model.removeAgent(row.id) }
        if outcome == .dismiss { controller.sheet = nil; checking.cancel() }
        release.signal()
        #expect(await eventually { harness.snapshots[.agy] != nil })
        #expect(model.models(for: .agy).map(\.id) == (outcome == .offline ? [] : ["model"]))
        if outcome == .dismiss { #expect(controller.sheet == nil) }
        if outcome == .offline { #expect(model.context.worker(.agy)?.help?.contains("couldn’t be launched") == true) }
        #expect(model.name == "Typed while loading")
        #expect(model.agentRows.map(\.id) == (editing ? [row.id] : []))
        #expect(calls.withLock { $0 } == 1)
    }

    /// The footer's "not installed" is read from the harness home the controller was given — in a
    /// test a temporary one — not from the developer's own `~/.claude`. Both answers are checked, so
    /// reading the real home fails whichever state it is in.
    @Test func theStatusLineProbeReadsTheHarnessHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), resources = root.appendingPathComponent("resources")
        let shim = resources.appendingPathComponent("hooks/claude-statusline-shim.sh")
        try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        let controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(),
                                       harnessHome: home, bundledResourcesURL: resources)

        await controller.agents.refreshStatusLineState()
        #expect(!controller.agents.claudeStatusLineInstalled, "this home has no Claude settings at all")

        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"statusLine":{"type":"command","command":"\#(shim.path)"}}"#.utf8).write(to: settings)
        await controller.agents.refreshStatusLineState()
        #expect(controller.agents.claudeStatusLineInstalled)
    }

    /// A sheet's models and prompt completions come from the harness home the controller was
    /// given, not the developer's own `~/.claude`: in a test that is a temporary directory.
    @Test func aCreationSheetReadsTheHarnessHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let skill = home.appendingPathComponent(".claude/skills/only-in-this-home")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: only-in-this-home\n---\n".write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try Data(#"{"availableModels":["model-only-in-this-home"]}"#.utf8)
            .write(to: home.appendingPathComponent(".claude/settings.json"))
        let controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(),
                                       harnessHome: home, bundledResourcesURL: nil)
        let project = Project.make(name: "Repo", path: root.path, addedAt: Date())
        let model = controller.sheets.makeCreationModel(
            project: project, draft: TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil), jira: nil)

        await model.loadAgentCatalogue()
        await model.loadSkills()
        #expect(model.models.contains { $0.id == "model-only-in-this-home" })
        #expect(model.completions.all.contains { $0.name == "only-in-this-home" })
    }

    /// Settings opens on the saved connections, read off the main actor: a
    /// Keychain that asks for access would hold the whole app on it.
    @Test func settingsReadsTheSavedConnectionsOffTheMainActor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let jira = JiraConfig(siteURL: URL(string: "https://example.atlassian.net")!, email: "a@b", token: "t")
        let onMain = Mutex<[Bool]>([])
        let controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(),
                                       harnessHome: root, bundledResourcesURL: nil,
                                       jiraSettings: { onMain.withLock { $0.append(Thread.isMainThread) }; return jira },
                                       gitLabSettings: { onMain.withLock { $0.append(Thread.isMainThread) }; return nil },
                                       gitHubSettings: { nil })
        controller.sheets.presentSettings()
        await eventually { controller.sheet != nil }
        guard case .settings(let saved, let gitLab, _, _, _)? = controller.sheet else { Issue.record("expected the Settings sheet"); return }
        #expect(saved == jira && gitLab == nil)
        #expect(onMain.withLock { $0 } == [false, false])
    }

    /// The sidebar's "Fix in Settings" opens Agents at that agent's card.
    @Test func settingsOpensAtAnAgentsCard() async throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        controller.sheets.presentSettings(tab: .integrations, agent: .codex)
        await eventually { controller.sheet != nil }
        guard case .settings(_, _, _, let tab, let agent)? = controller.sheet else { Issue.record("expected the Settings sheet"); return }
        #expect(tab == .agents && agent == .codex)
        let view = SettingsView(jiraConfig: nil, gitLabConfig: nil, harnessModel: .preview(),
                                itermConnection: { .waitingForIterm }, checkIterm: { ItermEnvironment(installed: true, pythonAPIEnabled: true) },
                                preferences: .scratch(), setMatchItermBackground: { _ in }, setInterfaceSize: { _ in },
                                initialAgent: .codex)
        #expect(view.tab == .agents, "on Agents, though iTerm2 would open it on Integrations")
        #expect(view.initialAgent == .codex)
    }

    /// ⌘, behind another sheet would replace it — and a New Task draft with it — so it does nothing.
    @Test func settingsDoesNotReplaceAnOpenSheet() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        controller.sheets.presentNewDivider()
        #expect(!controller.canPresentSettings)

        controller.sheets.presentSettings()

        #expect(controller.sheet?.id == AppController.SheetKind.newDivider.id)
    }

    /// The launch probe records the hook port in the supplied harness home.
    @Test func theLaunchProbeRecordsTheHookPort() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let support = home.appendingPathComponent("Library/Application Support/AiTerm")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(),
                                       harnessHome: home, bundledResourcesURL: nil)

        await controller.agents.probeStatusLine()
        #expect(try String(contentsOf: AiTermPaths.hookPortURL(home: home), encoding: .utf8) == "\(AiTermPaths.hookPort)\n")
    }

    /// A test that builds a controller and never scripts its prompter must fail when the app asks a
    /// question, not open a modal `NSAlert` that blocks the run: the default answers nothing.
    @Test func aTestControllerFailsAnUnexpectedQuestionRatherThanAskingModally() async {
        let controller = AppController(preferences: .scratch())
        let prompter = controller.prompter as? ScriptedPrompter
        #expect(prompter != nil, "the test initializer's prompter is scripted, not modal")

        var answer: AlertAnswer?
        await withKnownIssue("the prompter was not told to expect a question") {
            answer = await controller.prompter.ask(AlertPrompt(message: "Remove task?", buttons: ["Remove", "Cancel"], escape: 1))
        }
        #expect(answer?.button == 1, "it answers with the button ⎋ gives")
        #expect(prompter?.asked.map(\.message) == ["Remove task?"])
    }
}
