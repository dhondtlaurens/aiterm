import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// A snapshot of iTerm2 against the workspace (`AppState.reconciled`): which rows are owed their
/// window because the snapshot lacks it. Taking a window back by its tag is `WindowPlanTests`'.
@Suite struct WindowReconciliationTests {
    let project = UUID()

    func task(window: String?) -> TaskItem {
        TaskItem.make(project: project, title: "t", branch: "b", worktreePath: "/w", windowId: window)
    }

    func terminal(window: String?) -> TerminalItem {
        TerminalItem(id: UUID(), projectId: project, name: "Terminal", windowId: window, createdAt: Date(timeIntervalSince1970: 0))
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

    /// Every row whose window the snapshot lacks is left without one — a task's and a terminal's alike.
    @Test func aRowWhoseWindowIsGoneIsCleared() {
        let (kept, gone) = (task(window: "w1"), task(window: "w9"))
        let (open, closed) = (terminal(window: "w2"), terminal(window: "w8"))
        var state = AppState.empty
        state.tasks = [kept, gone]
        state.terminals = [open, closed]
        let next = state.reconciled(with: snapshot([SessionInfo.make("a", task: kept.id), SessionInfo.make("b", window: "w2")]))
        #expect(next.tasks.map(\.windowId) == ["w1", nil])
        #expect(next.terminals.map(\.windowId) == ["w2", nil])
    }

    /// The Operator's chat is a row like any other: a connected snapshot without its window clears it, a
    /// disconnected one does not, and during a handover, whose own record it is, neither does.
    @Test func theOperatorsChatWindowIsClearedOnlyByAConnectedSnapshotOutsideAHandover() {
        var state = AppState.empty
        state.operatorSession = OperatorSession(createdAt: Date(timeIntervalSince1970: 0))
        state.operatorSession?.window = "chat"
        #expect(state.reconciled(with: snapshot([], connected: false)) == state)
        #expect(state.reconciled(with: snapshot([SessionInfo.make("o", window: "chat")])) == state)
        #expect(state.reconciled(with: snapshot([])).operatorSession?.window == nil)
        for handover in [OperatorHandover.closing, .revoking, .opening] {
            state.operatorSession?.handover = handover
            #expect(state.reconciled(with: snapshot([])) == state, "\(handover)")
            #expect(state.reconciled(with: snapshot([], connected: false)) == state, "\(handover)")
        }
    }
}
