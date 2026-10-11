import Foundation
import Testing
@testable import AiTermCore

/// A snapshot of iTerm2 against the workspace (`AppState.reconciled`): which rows are owed their
/// window because the snapshot lacks it. Taking a window back by its tag is `WindowPlanTests`'.
@Suite struct WindowReconciliationTests {
    let project = UUID()

    func task(window: String?) -> TaskItem {
        TaskItem(id: UUID(), projectId: project, title: "t", branch: "b", worktreePath: "/w", baseBranch: "main", jira: nil,
                 agent: .claude, model: "m", reasoning: nil, firstPrompt: nil, appendTicket: false,
                 createdAt: Date(timeIntervalSince1970: 0), windowId: window)
    }

    func terminal(window: String?) -> TerminalItem {
        TerminalItem(id: UUID(), projectId: project, name: "Terminal", windowId: window, createdAt: Date(timeIntervalSince1970: 0))
    }

    func tab(_ id: String, window: String, task: TaskItem? = nil) -> SessionInfo {
        SessionInfo(sessionId: id, windowId: window, tabIndex: 0, taskId: task?.id.uuidString, projectId: nil, agent: .claude,
                    model: nil, state: .idle, title: "", cwd: "/")
    }

    func snapshot(_ tabs: [SessionInfo], connected: Bool = true) -> DaemonSnapshot {
        DaemonSnapshot(protocolVersion: 1, connected: connected, sessions: tabs, usage: .empty)
    }

    /// Out of reach, iTerm2 lists no windows, and that says nothing about any row.
    @Test func aDisconnectedSnapshotChangesNothing() {
        var state = AppState.empty
        state.tasks = [task(window: "w1")]
        state.terminals = [terminal(window: "w2")]
        #expect(state.reconciled(with: snapshot([], connected: false)) == state)
    }

    /// Every row whose window the snapshot lacks is owed it — a task's and a terminal's alike; the plan
    /// (`AppState.windowPlan`) decides what follows.
    @Test func aRowWhoseWindowIsGoneIsOwedIt() {
        let (kept, gone) = (task(window: "w1"), task(window: "w9"))
        let (open, closed) = (terminal(window: "w2"), terminal(window: "w8"))
        var state = AppState.empty
        state.tasks = [kept, gone]
        state.terminals = [open, closed]
        let next = state.reconciled(with: snapshot([tab("a", window: "w1", task: kept), tab("b", window: "w2")]))
        #expect(next.tasks.map(\.windowId) == ["w1", nil])
        #expect(next.terminals.map(\.windowId) == ["w2", nil])
    }
}
