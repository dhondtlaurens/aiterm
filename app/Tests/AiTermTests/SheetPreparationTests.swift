import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

extension AppControllerTests {
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
        let project = Project(id: UUID(), name: "Repo", path: root.path, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let model = controller.sheets.makeCreationModel(
            project: project, draft: TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil), jira: nil)

        await model.loadAgentCatalogue()
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
        controller.presentSettings()
        await eventually { controller.sheet != nil }
        guard case .settings(let saved, let gitLab, _, _, _)? = controller.sheet else { Issue.record("expected the Settings sheet"); return }
        #expect(saved == jira && gitLab == nil)
        #expect(onMain.withLock { $0 } == [false, false])
    }

    /// The sidebar's "Fix in Settings" opens Agents at that agent's card.
    @Test func settingsOpensAtAnAgentsCard() async throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        controller.presentSettings(tab: .integrations, agent: .codex)
        await eventually { controller.sheet != nil }
        guard case .settings(_, _, _, let tab, let agent)? = controller.sheet else { Issue.record("expected the Settings sheet"); return }
        #expect(tab == .agents && agent == .codex)
        let view = SettingsView(jiraConfig: nil, gitLabConfig: nil, harnessModel: .preview(),
                                itermConnection: { .waitingForIterm }, checkIterm: { ItermEnvironment(installed: true, pythonAPIEnabled: true) },
                                preferences: .scratch(), setMatchItermBackground: { _ in }, setInterfaceSize: { _ in },
                                initialAgent: .codex)
        #expect(view._tab.wrappedValue == .agents, "on Agents, though iTerm2 would open it on Integrations")
        #expect(view.initialAgent == .codex)
    }

    /// ⌘, behind another sheet would replace it — and a New Task draft with it — so it does nothing.
    @Test func settingsDoesNotReplaceAnOpenSheet() throws {
        let (controller, dir) = try loadedController()
        defer { try? FileManager.default.removeItem(at: dir) }
        controller.presentNewDivider()
        #expect(!controller.canPresentSettings)

        controller.presentSettings()

        #expect(controller.sheet?.id == AppController.SheetKind.newDivider.id)
    }

    /// An upgrade from a build whose record of the user's status line the shim no longer reads is
    /// migrated at launch, in the harness home: nothing would prompt a repair that does it.
    @Test func theLaunchProbeMigratesAnOldStatusLineRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let support = home.appendingPathComponent("Library/Application Support/AiTerm")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data(#"{"type":"command","command":"my-statusline"}"#.utf8).write(to: support.appendingPathComponent("statusline-original.json"))
        let controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(),
                                       harnessHome: home, bundledResourcesURL: nil)

        await controller.agents.probeStatusLine()
        let command = support.appendingPathComponent("statusline-original.cmd")
        #expect(try String(contentsOf: command, encoding: .utf8) == "my-statusline")
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
