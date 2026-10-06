import Foundation
import Testing
@testable import AiTermCore

/// A snapshot of iTerm2 against the workspace (`AppState.reconciled`): which rows take a window
/// back by their tag, and which go because their window has.
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
        #expect(state.reconciled(with: snapshot([], connected: false), lettingGo: []) == state)
    }

    /// A row whose window the snapshot lists stays; one whose window it lacks goes, task or terminal.
    @Test func rowsWhoseWindowsAreGoneGo() {
        let (kept, gone) = (task(window: "w1"), task(window: "w9"))
        let (open, closed) = (terminal(window: "w2"), terminal(window: "w8"))
        let windowless = terminal(window: nil)
        var state = AppState.empty
        state.tasks = [kept, gone]
        state.terminals = [open, closed, windowless]
        let next = state.reconciled(with: snapshot([tab("a", window: "w1", task: kept), tab("b", window: "w2")]), lettingGo: [])
        #expect(next.tasks == [kept])
        #expect(next.terminals == [open, windowless], "a row with no window has none to lose")
    }

    /// A task finds its window again by the tag on its tab — a create whose reply was lost, or a
    /// window that moved — the first tagged tab winning; a task with no tab keeps the one it had.
    @Test func aTaskTakesTheWindowItsTagIsIn() {
        let lost = task(window: nil), moved = task(window: "w1"), untouched = task(window: "w3")
        var state = AppState.empty
        state.tasks = [lost, moved, untouched]
        let next = state.reconciled(with: snapshot([tab("a", window: "w5", task: lost), tab("b", window: "w6", task: lost),
                                                    tab("c", window: "w2", task: moved), tab("d", window: "w3")]),
                                    lettingGo: [])
        #expect(next.tasks.map(\.windowId) == ["w5", "w2", "w3"])
    }

    /// A task whose removal has let its window go is not handed it back: the window would take the
    /// row with it when it closes.
    @Test func aTaskLettingItsWindowGoIsNotGivenItBack() {
        let leaving = task(window: nil)
        var state = AppState.empty
        state.tasks = [leaving]
        let next = state.reconciled(with: snapshot([tab("a", window: "w1", task: leaving)]), lettingGo: [leaving.id])
        #expect(next == state)
    }
}
