import Foundation
import Testing
@testable import AiTermCore

/// The Dock badge counts the rows Focus View steps through: needing input, or done and unseen,
/// terminals included — read from the same sections the sidebar draws.
@Suite struct DockBadgeTests {
    private let project = Project(id: UUID(), name: "repo", path: "/repo", provider: .git, remoteUrl: nil,
                                  addedAt: Date(), collapsed: false)

    private func task(windowId: String?) -> TaskItem {
        TaskItem(id: UUID(), projectId: project.id, title: "Task", branch: "task",
                 worktreePath: "/tmp/task", baseBranch: "main", jira: nil, agent: .claude,
                 model: "model", reasoning: nil, firstPrompt: nil, appendTicket: true,
                 createdAt: Date(), windowId: windowId)
    }

    private func session(_ id: String, window: String, taskId: String?, state: SessionState) -> SessionInfo {
        SessionInfo(sessionId: id, windowId: window, tabIndex: 0,
                    taskId: taskId, projectId: nil, agent: .claude, model: nil,
                    state: state, title: "", cwd: "/tmp")
    }

    private func label(_ state: AppState, _ sessions: [SessionInfo], skipping: Set<UUID> = []) -> String? {
        DockBadge.label(for: SidebarModel.sections(state: state, sessions: sessions, branchByCwd: [:], projectBranch: [:]),
                        skippingTasks: skipping)
    }

    private func state(tasks: [TaskItem], terminals: [TerminalItem] = []) -> AppState {
        var state = AppState.empty
        state.items = [.project(project)]; state.tasks = tasks; state.terminals = terminals
        return state
    }

    @Test func theBadgeIsHiddenWhenNothingWaits() {
        let open = task(windowId: "task-window")
        #expect(label(state(tasks: [open]), [
            session("working", window: "task-window", taskId: open.id.uuidString, state: .working),
            session("idle", window: "task-window", taskId: open.id.uuidString, state: .idle),
        ]) == nil)
    }

    /// A row counts once, whichever of its tabs is waiting and however many are.
    @Test func theBadgeCountsRowsThatNeedInputOnceEach() {
        let first = task(windowId: "first-window"), second = task(windowId: "second-window")
        #expect(label(state(tasks: [first, second]), [
            session("first-a", window: "first-window", taskId: first.id.uuidString, state: .needsInput),
            session("first-b", window: "first-window", taskId: first.id.uuidString, state: .needsInput),
            session("second", window: "second-window", taskId: second.id.uuidString, state: .needsInput),
        ]) == "2")
    }

    /// Done is unseen until the row is chosen — a seen completion is idle — so it counts, as Focus
    /// View steps to it.
    @Test func aDoneRowCountsLikeOneNeedingInput() {
        let asking = task(windowId: "asking-window"), finished = task(windowId: "finished-window")
        #expect(label(state(tasks: [asking, finished]), [
            session("asking", window: "asking-window", taskId: asking.id.uuidString, state: .needsInput),
            session("finished", window: "finished-window", taskId: finished.id.uuidString, state: .done),
        ]) == "2")
    }

    /// A terminal's tabs carry no task tag: they are its row's by window, as the sidebar draws them.
    @Test func aTerminalCounts() {
        let shell = TerminalItem(id: UUID(), projectId: project.id, name: "Terminal", windowId: "terminal-window", createdAt: Date())
        #expect(label(state(tasks: [], terminals: [shell]), [
            session("terminal", window: "terminal-window", taskId: nil, state: .needsInput),
        ]) == "1")
    }

    @Test func tabsWithoutARowAreNotCounted() {
        #expect(label(state(tasks: [task(windowId: "task-window")]), [
            session("unknown", window: "elsewhere", taskId: UUID().uuidString, state: .needsInput),
            session("stray", window: "stray-window", taskId: nil, state: .done),
        ]) == nil)
    }

    /// A task on its way out is passed over, as Focus View passes over it.
    @Test func aTaskBeingRemovedIsNotCounted() {
        let leaving = task(windowId: "leaving-window")
        let tabs = [session("leaving", window: "leaving-window", taskId: leaving.id.uuidString, state: .needsInput)]
        #expect(label(state(tasks: [leaving]), tabs) == "1")
        #expect(label(state(tasks: [leaving]), tabs, skipping: [leaving.id]) == nil)
    }
}
