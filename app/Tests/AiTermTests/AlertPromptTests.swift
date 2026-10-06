import AppKit
import Testing
import AiTermCore
@testable import AiTerm

/// Every alert has one default button, on ↩, blue — or red only when it deletes — and ⎋ answers
/// its safe choice. Built, never run: `ModalPrompter.alert(for:)` is the alert `ask` would show.
@Suite @MainActor struct AlertPromptTests {
    private static let escape = "\u{1b}", enter = "\r"

    @Test func onlyADefaultThatDeletesIsRed() {
        let remove = ModalPrompter.alert(for: AlertPrompt(message: "Remove task?", buttons: ["Remove", "Cancel"], defaultDeletes: true))
        #expect(remove.buttons.map(\.hasDestructiveAction) == [true, false])
        let project = ModalPrompter.alert(for: AlertPrompt(message: "Remove project?", buttons: ["Remove", "Cancel"]))
        #expect(project.buttons.map(\.hasDestructiveAction) == [false, false], "a project's files are kept: blue")
        let unsaved = ModalPrompter.alert(for: AlertPrompt(message: "Uncommitted changes",
                                                           buttons: ["Keep Task", "Delete Changes and Remove"], escape: 0))
        #expect(unsaved.buttons.map(\.hasDestructiveAction) == [false, false],
                "a destructive button that isn't the default is the plain grey one")
    }

    @Test func theDefaultAnswersReturnAndTheSafeChoiceEscape() {
        let remove = ModalPrompter.alert(for: AlertPrompt(message: "Remove task?", buttons: ["Remove", "Cancel"], defaultDeletes: true))
        #expect(remove.buttons.map(\.keyEquivalent) == [Self.enter, Self.escape])
        let later = ModalPrompter.alert(for: AlertPrompt(message: "Update?", buttons: ["Update", "Later"], escape: 1))
        #expect(later.buttons.map(\.keyEquivalent) == [Self.enter, Self.escape], "Later is handed ⎋: NSAlert gives it only to Cancel")
        // A safe default keeps ↩; `ask` answers ⎋ for it.
        let quit = ModalPrompter.alert(for: AlertPrompt(message: "Unsaved", buttons: ["Cancel Quit", "Quit Without Saving"], escape: 0))
        #expect(quit.buttons.map(\.keyEquivalent) == [Self.enter, ""])
    }

    @Test func escapeFallsToCancelOrALoneButton() {
        #expect(AlertPrompt(message: "m", buttons: ["Remove", "Cancel"]).escapeButton == 1)
        #expect(AlertPrompt(message: "m").escapeButton == 0, "an OK-only alert: ⎋ is OK")
        #expect(AlertPrompt(message: "m", buttons: ["Import", "Skip"], escape: 1).escapeButton == 1)
        #expect(AlertPrompt(message: "m", buttons: ["Keep Task", "Delete Changes and Remove"], escape: 0).escapeButton == 0)
    }

    /// The table in the consistency spec's section 9, as the app asks it.
    @Test func theRemoveTaskAlertHasARedDefaultAndCancelOnEscape() async throws {
        let prompter = ScriptedPrompter(answering: "⎋")
        let fixture = try RaceFixture(prompter: prompter)
        defer { fixture.cleanUp() }
        let task = TaskItem(id: UUID(), projectId: fixture.project.id, title: "Work", branch: "feat/work",
                            worktreePath: fixture.repo.path + "/.worktrees/work", baseBranch: "main", jira: nil,
                            agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil, appendTicket: false,
                            createdAt: Date(), windowId: nil)
        fixture.controller.workspace.mutate { $0.tasks = [task] }

        #expect(fixture.controller.confirmRemove(task: task) == nil, "⎋ cancels")
        let asked = try #require(prompter.asked.first)
        #expect(asked.buttons == ["Remove", "Cancel"])
        #expect(asked.defaultDeletes)
        #expect(asked.escapeButton == 1)
        #expect(fixture.controller.state.tasks == [task])
    }

    @Test func theRemoveProjectAlertIsBlueBecauseItKeepsTheFiles() throws {
        let prompter = ScriptedPrompter(answering: "⎋")
        let fixture = try RaceFixture(prompter: prompter)
        defer { fixture.cleanUp() }

        fixture.controller.confirmRemove(project: fixture.project)

        let asked = try #require(prompter.asked.first)
        #expect(asked.buttons == ["Remove", "Cancel"])
        #expect(!asked.defaultDeletes)
        #expect(fixture.controller.state.projects == [fixture.project], "⎋ cancels")
    }

    @Test func escapeSkipsTheWorktreeImport() async throws {
        let fixture = try RaceFixture(prompter: ScriptedPrompter(answering: "⎋"))
        defer { fixture.cleanUp() }
        let controller = fixture.controller
        controller.workspace.mutate { $0.items = [] }
        #expect(controller.workspace.flush())
        try fixture.git.run(["worktree", "add", "-q", "-b", "feat/old", fixture.repo.path + "/.worktrees/old"], in: fixture.repo.path)

        await controller.addProject(path: fixture.repo.path)

        #expect(fixture.prompter.asked.map(\.message) == ["Import 1 worktree?"])
        #expect(controller.state.projects.map(\.path) == [fixture.repo.path])
        #expect(controller.state.tasks.isEmpty, "⎋ is Skip")
    }
}
