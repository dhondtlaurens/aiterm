import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The conversations a task's window shows are saved with the task as the helper reports them, so a
/// reopen can resume them after the window, the app or the Mac went away.
extension AppControllerTests {
    private func conversationTab(_ id: String, _ index: Int, _ agent: SessionAgent, _ conversation: String?,
                                 of task: TaskItem) -> SessionInfo {
        SessionInfo(sessionId: id, windowId: "w1", tabIndex: index, taskId: task.id.uuidString, projectId: nil,
                    agent: agent, model: nil, state: .idle, title: "", cwd: task.worktreePath, conversationId: conversation)
    }

    @Test func aTaskKeepsItsConversationsWhenItsWindowsTabsGo() throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let task = try fixture.addTask(windowId: "w1")

        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true,
                                                          sessions: [conversationTab("a", 0, .codex, "thread-1", of: task)],
                                                          usage: .empty)))
        #expect(controller.state.task(id: task.id)?.conversations == [TaskConversation(agent: .codex, id: "thread-1")])

        controller.helper.handle(.sessionOpened(conversationTab("b", 1, .claude, nil, of: task)))
        controller.helper.handle(.sessionChanged(conversationTab("b", 1, .claude, "conv-2", of: task)))
        let both = [TaskConversation(agent: .codex, id: "thread-1"), TaskConversation(agent: .claude, id: "conv-2")]
        #expect(controller.state.task(id: task.id)?.conversations == both)

        // The window closing takes its tabs: what they showed stays for the reopen, on disk too.
        controller.helper.handle(.sessionClosed("a"))
        controller.helper.handle(.sessionClosed("b"))
        #expect(controller.state.task(id: task.id)?.conversations == both)
        #expect(try controller.savedWorkspace().task(id: task.id)?.conversations == both)
    }

    /// A tab closed by hand, with its window still open, is not reopened: the next change in the window
    /// remembers only what it shows.
    @Test func aTabClosedByHandDropsItsConversationOnTheWindowsNextChange() throws {
        let fixture = try RaceFixture()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        let task = try fixture.addTask(windowId: "w1")
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
            conversationTab("a", 0, .codex, "thread-1", of: task), conversationTab("b", 1, .claude, "conv-2", of: task),
        ], usage: .empty)))

        controller.helper.handle(.sessionClosed("a"))
        controller.helper.handle(.sessionChanged(conversationTab("b", 0, .claude, "conv-2", of: task)))

        #expect(controller.state.task(id: task.id)?.conversations == [TaskConversation(agent: .claude, id: "conv-2")])
    }
}
