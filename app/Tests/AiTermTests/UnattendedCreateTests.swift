import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A project signal's create makes its row without the person: saved with what its caller writes in the same change,
/// with nothing chosen, opened or brought forward. Its window opens later, behind, with the ordinary agent command.
@MainActor @Suite(.blocking) struct UnattendedCreateTests {
    /// The row and what `saving` wrote are one change: the workspace never held the row without its origin, and the
    /// file holds both once the create returns. The person's selection stays where it was, no window opens, and the
    /// signal's agent is not remembered as the person's last choice.
    @Test func anUnattendedTaskIsSavedWithWhatItsCallerWroteAndChoosesNothing() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let mine = try await fixture.addTask(windowId: "alive")
        controller.focus.browse(.task(mine.id))
        var bare: [UUID] = []
        controller.workspace.onChange {
            bare += controller.state.tasks.filter { $0.id != mine.id && $0.signalOrigin == nil }.map(\.id)
        }

        let id = try await controller.launcher.createUnattended(.init(project: fixture.project, kind: .task(fixture.draft("Picked up")),
                                                                      saving: { state, id in Self.mark(id, in: &state) }))

        #expect(bare.isEmpty, "the row is never in the workspace without what its caller saves with it")
        let saved = try controller.workspace.file.load()
        #expect(saved.task(id: id)?.signalOrigin == Self.origin, "saved by the create's own flush")
        #expect(saved.task(id: id)?.title == "Picked up" && saved.task(id: id)?.windowId == nil)
        #expect(controller.focus.selectedTaskId == mine.id)
        #expect(server.requests("window.createTask").isEmpty && server.requests("tab.create").isEmpty)
        #expect(server.requests("window.activate").isEmpty)
        #expect(controller.state.lastAgentByProject[fixture.project.id] == nil)
    }

    /// A project creating a task for the person says so as a sheet hears it, and the pick-up can wait for its turn.
    @Test func aProjectBusyCreatingThrowsCreationBusy() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon(holding: "window.createTask")
        defer { server.release(); fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let first = Task { try await controller.launcher.createTask(draft: fixture.draft("First"), project: fixture.project) }
        try await server.received("window.createTask")

        await #expect {
            _ = try await controller.launcher.createUnattended(.init(project: fixture.project, kind: .task(fixture.draft("Second")),
                                                                     saving: { _, _ in }))
        } throws: { ($0 as? CreationBusy)?.localizedDescription == "A task or review is already being created in Repo. Try again once it is." }
        server.release()
        try await first.value
        #expect(controller.state.tasks.map(\.title) == ["First"])
    }

    /// A sheet's review of a branch a row has checked out opens in that row's window and brings it forward. A pick-up
    /// never does: it fails with the row's name, and nothing opens, comes forward or is added.
    @Test func aReviewOfABranchARowHasThrowsWithItsTitleAndOpensNothing() async throws {
        let fixture = try await TaskFixture(windowOpen: true, provider: .gitlab)
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        var draft = ReviewDraft(mr: nil, agent: .claude, model: "sonnet", reasoning: nil)
        draft.apply(mr: MergeRequest(iid: 7, title: "Work", sourceBranch: "feat/work", targetBranch: "main",
                                     author: "someone", state: "opened", draft: false, url: "https://gitlab/x/-/merge_requests/7"))

        await #expect {
            _ = try await fixture.controller.launcher.createUnattended(.init(project: fixture.project, kind: .review(draft),
                                                                             saving: { _, _ in }))
        } throws: { ($0 as? ActionUnavailable)?.message.contains("“\(fixture.task.title)”") == true }

        #expect(server.requests("tab.create").isEmpty && server.requests("window.activate").isEmpty)
        #expect(server.requests("window.createTask").isEmpty)
        #expect(fixture.controller.state.tasks == [fixture.task])
    }

    /// The window opens behind, with the ordinary command for the prompt, and `saving` lands with the window's id.
    @Test func openingAnUnattendedTaskAsksForABackgroundWindow() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let id = try await controller.launcher.createUnattended(.init(project: fixture.project, kind: .task(fixture.draft("Picked up")),
                                                                      saving: { state, id in Self.mark(id, in: &state) }))

        try await controller.launcher.openUnattended(id, prompt: "Go on") { state in
            if let i = state.tasks.firstIndex(where: { $0.id == id }) { state.tasks[i].signalOrigin?.name = "Opened" }
        }

        let window = try #require(server.requests("window.createTask").first)
        #expect(window.params["background"] as? Bool == true)
        let command = try #require(window.params["agentCommand"] as? String)
        #expect(command.hasPrefix("claude ") && command.hasSuffix("'Go on'"))
        #expect(!command.contains("--disallowedTools") && !command.contains("--resume"))
        #expect(server.requests("window.activate").isEmpty && server.requests("tab.create").isEmpty)
        let saved = try #require(try controller.savedWorkspace().task(id: id))
        #expect(saved.windowId == "reopened" && saved.signalOrigin?.name == "Opened")
        #expect(controller.focus.selectedTaskId == nil)
    }

    /// The caller's last look comes after the folder check and the command, with no await before the window is asked
    /// for: typing that resumed meanwhile opens nothing, runs no `saving` and answers false; asked again, it opens.
    @Test func theLastLookAfterPreparationHoldsTheWindow() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: nil)
        var looks = 0, saved = false

        let held = try await controller.launcher.openUnattended(task.id, prompt: "Go on", saving: { _ in saved = true },
                                                                mayOpen: { looks += 1; return false })
        #expect(!held && looks == 1 && !saved)
        #expect(server.requests("window.createTask").isEmpty && server.requests("tab.create").isEmpty)
        #expect(controller.state.task(id: task.id)?.windowId == nil)

        let opened = try await controller.launcher.openUnattended(task.id, prompt: "Go on", saving: { _ in saved = true })
        #expect(opened && saved && server.requests("window.createTask").count == 1)
    }

    /// A task with conversations resumes the first of its own agent with the prompt, and every other in a background tab.
    @Test func openingResumesTheFirstConversationWithThePromptAndTheOthersBehind() async throws {
        let fixture = try await RaceFixture()
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: nil)
        controller.workspace.mutate {
            $0.tasks[0].conversations = [TaskConversation(agent: .claude, id: "by-hand"), TaskConversation(agent: .codex, id: "thread-1")]
        }

        try await controller.launcher.openUnattended(task.id, prompt: "Again")

        let window = try #require(server.requests("window.createTask").first)
        #expect(window.params["background"] as? Bool == true)
        let command = try #require(window.params["agentCommand"] as? String)
        #expect(command.hasPrefix("codex resume thread-1 ") && command.hasSuffix("'Again'"))
        let tabs = server.requests("tab.create")
        #expect(tabs.count == 1)
        #expect(tabs.first?.params["background"] as? Bool == true)
        #expect((tabs.first?.params["agentCommand"] as? String)?.hasPrefix("claude --resume by-hand") == true)
        #expect(server.requests("window.activate").isEmpty)
    }

    /// A window that is open with no agent gets the command in a background tab of its own; no second window opens.
    @Test func anOpenWindowWithNoAgentGetsABackgroundTab() async throws {
        let fixture = try await TaskFixture(windowOpen: true)
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        fixture.controller.helper.setDaemonClient(server)
        var saved = false

        try await fixture.controller.launcher.openUnattended(fixture.task.id, prompt: "Go on") { _ in saved = true }

        let tab = try #require(server.requests("tab.create").first)
        #expect(tab.params["windowId"] as? String == "alive" && tab.params["background"] as? Bool == true)
        #expect((tab.params["agentCommand"] as? String)?.hasSuffix("'Go on'") == true)
        #expect(server.requests("window.createTask").isEmpty && server.requests("window.activate").isEmpty)
        #expect(saved)
    }

    private static let origin = SignalOrigin(signal: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!, name: "Reviews",
                                             item: .ticket(site: "https://tickets.example", key: "T-1"),
                                             startedAt: Date(timeIntervalSince1970: 1_800_000_000))

    private static func mark(_ id: UUID, in state: inout AppState) {
        if let i = state.tasks.firstIndex(where: { $0.id == id }) { state.tasks[i].signalOrigin = origin }
    }
}
