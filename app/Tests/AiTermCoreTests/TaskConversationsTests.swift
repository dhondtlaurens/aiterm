import Foundation
import Testing
@testable import AiTermCore

/// The conversations a task's window shows, remembered for its reopen (`AppState.rememberingConversations`).
@Suite struct TaskConversationsTests {
    let project = UUID()

    func task(window: String?, conversations: [TaskConversation] = []) -> TaskItem {
        TaskItem(id: UUID(), projectId: project, title: "t", branch: "b", worktreePath: "/w", baseBranch: "main", jira: nil,
                 agent: .claude, model: "m", reasoning: nil, firstPrompt: nil, appendTicket: false,
                 createdAt: Date(timeIntervalSince1970: 0), windowId: window, conversations: conversations)
    }

    func tab(_ id: String, window: String, index: Int, agent: SessionAgent, conversation: String?) -> SessionInfo {
        SessionInfo(sessionId: id, windowId: window, tabIndex: index, taskId: nil, projectId: nil, agent: agent, model: nil,
                    state: .idle, title: "", cwd: "/", conversationId: conversation)
    }

    func state(_ tasks: TaskItem...) -> AppState {
        var state = AppState.empty
        state.tasks = tasks
        return state
    }

    /// Every agent tab of the task's own window, once each has named its conversation, in tab order; a
    /// shell and another window's tab are not the task's.
    @Test func aTaskRemembersItsWindowsAgentConversationsInTabOrder() {
        let next = state(task(window: "w1")).rememberingConversations(from: [
            tab("c", window: "w1", index: 2, agent: .codex, conversation: "thread-3"),
            tab("a", window: "w1", index: 0, agent: .claude, conversation: "conv-1"),
            tab("s", window: "w1", index: 1, agent: .shell, conversation: nil),
            tab("x", window: "w2", index: 0, agent: .pi, conversation: "elsewhere"),
        ])
        #expect(next.tasks[0].conversations == [TaskConversation(agent: .claude, id: "conv-1"),
                                                 TaskConversation(agent: .codex, id: "thread-3")])
    }

    /// A reopened window's agents start one by one: while one has yet to name its conversation, what was
    /// remembered stays, so a quit or a late hook cannot cost the others their place.
    @Test func aWindowWithAnAgentYetToNameItsConversationLeavesWhatWasRemembered() {
        let remembered = [TaskConversation(agent: .codex, id: "thread-1"), TaskConversation(agent: .claude, id: "conv-2")]
        let before = state(task(window: "w1", conversations: remembered))
        let partly = [tab("a", window: "w1", index: 0, agent: .codex, conversation: "thread-1"),
                      tab("b", window: "w1", index: 1, agent: .claude, conversation: nil)]
        #expect(before.rememberingConversations(from: partly) == before)

        let both = [tab("a", window: "w1", index: 0, agent: .codex, conversation: "thread-9"),
                    tab("b", window: "w1", index: 1, agent: .claude, conversation: "conv-8")]
        #expect(before.rememberingConversations(from: both).tasks[0].conversations
                == [TaskConversation(agent: .codex, id: "thread-9"), TaskConversation(agent: .claude, id: "conv-8")])
    }

    /// Two panes share a tab's index: they are read in the order of their session ids, the same every time.
    @Test func twoPanesOfOneTabAreReadInAFixedOrder() {
        let next = state(task(window: "w1")).rememberingConversations(from: [
            tab("b", window: "w1", index: 0, agent: .codex, conversation: "thread-2"),
            tab("a", window: "w1", index: 0, agent: .claude, conversation: "conv-1"),
        ])
        #expect(next.tasks[0].conversations.map(\.id) == ["conv-1", "thread-2"])
    }

    /// A window that shows none — its tabs gone with it, or back at their shells — leaves what was
    /// remembered: that is what a reopen resumes. A windowless task keeps its own.
    @Test func aWindowShowingNoneLeavesWhatWasRemembered() {
        let remembered = [TaskConversation(agent: .claude, id: "conv-1")]
        let open = state(task(window: "w1", conversations: remembered))
        #expect(open.rememberingConversations(from: []) == open)
        #expect(open.rememberingConversations(from: [tab("s", window: "w1", index: 0, agent: .shell, conversation: nil)]) == open)
        let closed = state(task(window: nil, conversations: remembered))
        #expect(closed.rememberingConversations(from: [tab("a", window: "w1", index: 0, agent: .codex, conversation: "x")]) == closed)
    }

    /// An empty id would make a later resume open the CLI's picker, so it is never remembered.
    @Test func aTabNamingAnEmptyConversationIsNotRemembered() {
        let before = state(task(window: "w1"))
        #expect(before.rememberingConversations(from: [tab("a", window: "w1", index: 0, agent: .claude, conversation: "")]) == before)
    }

    @Test func aNewConversationReplacesTheOneItsTabHad() {
        let before = state(task(window: "w1", conversations: [TaskConversation(agent: .claude, id: "conv-1")]))
        let next = before.rememberingConversations(from: [tab("a", window: "w1", index: 0, agent: .claude, conversation: "conv-2")])
        #expect(next.tasks[0].conversations == [TaskConversation(agent: .claude, id: "conv-2")])
    }

    @Test func onlyTheTasksNamedAreRead() {
        let a = task(window: "w1"), b = task(window: "w2")
        let next = state(a, b).rememberingConversations(from: [
            tab("1", window: "w1", index: 0, agent: .claude, conversation: "conv-a"),
            tab("2", window: "w2", index: 0, agent: .claude, conversation: "conv-b"),
        ], only: [b.id])
        #expect(next.tasks.map(\.conversations.count) == [0, 1])
    }
}
