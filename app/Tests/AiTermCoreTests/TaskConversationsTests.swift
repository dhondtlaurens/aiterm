import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The conversations a task's window shows, remembered for its reopen (`AppState.rememberingConversations`).
@Suite struct TaskConversationsTests {
    let project = UUID()

    func task(window: String?, conversations: [TaskConversation] = []) -> TaskItem {
        TaskItem.make(project: project, title: "t", branch: "b", worktreePath: "/w", windowId: window,
            conversations: conversations)
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
            SessionInfo.make("c", tabIndex: 2, agent: .codex, conversation: "thread-3"),
            SessionInfo.make("a", conversation: "conv-1"),
            SessionInfo.make(tabIndex: 1, agent: .shell),
            SessionInfo.make("x", window: "w2", agent: .pi, conversation: "elsewhere"),
        ])
        #expect(next.tasks[0].conversations == [TaskConversation(agent: .claude, id: "conv-1"),
                                                 TaskConversation(agent: .codex, id: "thread-3")])
    }

    /// A reopened window's agents start one by one: while one has yet to name its conversation, what was
    /// remembered stays, so a quit or a late hook cannot cost the others their place.
    @Test func aWindowWithAnAgentYetToNameItsConversationLeavesWhatWasRemembered() {
        let remembered = [TaskConversation(agent: .codex, id: "thread-1"), TaskConversation(agent: .claude, id: "conv-2")]
        let before = state(task(window: "w1", conversations: remembered))
        let partly = [SessionInfo.make("a", agent: .codex, conversation: "thread-1"),
                      SessionInfo.make("b", tabIndex: 1)]
        #expect(before.rememberingConversations(from: partly) == before)

        let both = [SessionInfo.make("a", agent: .codex, conversation: "thread-9"),
                    SessionInfo.make("b", tabIndex: 1, conversation: "conv-8")]
        #expect(before.rememberingConversations(from: both).tasks[0].conversations
                == [TaskConversation(agent: .codex, id: "thread-9"), TaskConversation(agent: .claude, id: "conv-8")])
    }

    /// Two panes share a tab's index: they are read in the order of their session ids, the same every time.
    @Test func twoPanesOfOneTabAreReadInAFixedOrder() {
        let next = state(task(window: "w1")).rememberingConversations(from: [
            SessionInfo.make("b", agent: .codex, conversation: "thread-2"),
            SessionInfo.make("a", conversation: "conv-1"),
        ])
        #expect(next.tasks[0].conversations.map(\.id) == ["conv-1", "thread-2"])
    }

    /// A window that shows none — its tabs gone with it, or back at their shells — leaves what was
    /// remembered: that is what a reopen resumes. A windowless task keeps its own.
    @Test func aWindowShowingNoneLeavesWhatWasRemembered() {
        let remembered = [TaskConversation(agent: .claude, id: "conv-1")]
        let open = state(task(window: "w1", conversations: remembered))
        #expect(open.rememberingConversations(from: []) == open)
        #expect(open.rememberingConversations(from: [SessionInfo.make(agent: .shell)]) == open)
        let closed = state(task(window: nil, conversations: remembered))
        #expect(closed.rememberingConversations(from: [SessionInfo.make("a", agent: .codex, conversation: "x")]) == closed)
    }

    /// An empty id would make a later resume open the CLI's picker, so it is never remembered.
    @Test func aTabNamingAnEmptyConversationIsNotRemembered() {
        let before = state(task(window: "w1"))
        #expect(before.rememberingConversations(from: [SessionInfo.make("a", conversation: "")]) == before)
    }

    /// An id starting with "-" would be read by the agent's CLI as a flag, so it is never remembered —
    /// and, like an empty one, leaves what was.
    @Test func aTabNamingAConversationThatReadsAsAFlagIsNotRemembered() {
        let remembered = [TaskConversation(agent: .claude, id: "conv-1")]
        let before = state(task(window: "w1", conversations: remembered))
        #expect(before.rememberingConversations(from: [SessionInfo.make("a", conversation: "--model")]) == before)
        #expect(before.rememberingConversations(from: [SessionInfo.make("a", conversation: "-x")]) == before)
    }

    @Test func aNewConversationReplacesTheOneItsTabHad() {
        let before = state(task(window: "w1", conversations: [TaskConversation(agent: .claude, id: "conv-1")]))
        let next = before.rememberingConversations(from: [SessionInfo.make("a", conversation: "conv-2")])
        #expect(next.tasks[0].conversations == [TaskConversation(agent: .claude, id: "conv-2")])
    }

    @Test func onlyTheTasksNamedAreRead() {
        let a = task(window: "w1"), b = task(window: "w2")
        let next = state(a, b).rememberingConversations(from: [
            SessionInfo.make("1", conversation: "conv-a"),
            SessionInfo.make("2", window: "w2", conversation: "conv-b"),
        ], only: [b.id])
        #expect(next.tasks.map(\.conversations.count) == [0, 1])
    }
}
