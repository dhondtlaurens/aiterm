import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The Dock badge counts the rows Focus View steps through: needing input, or done and unseen,
/// terminals included — read from the same sections the sidebar draws.
@Suite struct DockBadgeTests {
    private let project = Project.make(name: "repo", path: "/repo", addedAt: Date())

    private func task(windowId: String?) -> TaskItem {
        TaskItem.make(project: project.id, title: "Task", branch: "task", worktreePath: "/tmp/task", model: "model",
            appendTicket: true, createdAt: Date(), windowId: windowId)
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
            SessionInfo.make("working", window: "task-window", task: open.id, state: .working, cwd: "/tmp"),
            SessionInfo.make("idle", window: "task-window", task: open.id, state: .idle, cwd: "/tmp"),
        ]) == nil)
    }

    /// A row counts once, whichever of its tabs is waiting and however many are.
    @Test func theBadgeCountsRowsThatNeedInputOnceEach() {
        let first = task(windowId: "first-window"), second = task(windowId: "second-window")
        #expect(label(state(tasks: [first, second]), [
            SessionInfo.make("first-a", window: "first-window", task: first.id, state: .needsInput, cwd: "/tmp"),
            SessionInfo.make("first-b", window: "first-window", task: first.id, state: .needsInput, cwd: "/tmp"),
            SessionInfo.make("second", window: "second-window", task: second.id, state: .needsInput, cwd: "/tmp"),
        ]) == "2")
    }

    /// Done is unseen until the row is chosen — a seen completion is idle — so it counts, as Focus
    /// View steps to it.
    @Test func aDoneRowCountsLikeOneNeedingInput() {
        let asking = task(windowId: "asking-window"), finished = task(windowId: "finished-window")
        #expect(label(state(tasks: [asking, finished]), [
            SessionInfo.make("asking", window: "asking-window", task: asking.id, state: .needsInput, cwd: "/tmp"),
            SessionInfo.make("finished", window: "finished-window", task: finished.id, state: .done, cwd: "/tmp"),
        ]) == "2")
    }

    /// A terminal's tabs carry no task tag: they are its row's by window, as the sidebar draws them.
    @Test func aTerminalCounts() {
        let shell = TerminalItem(id: UUID(), projectId: project.id, name: "Terminal", windowId: "terminal-window", createdAt: Date())
        #expect(label(state(tasks: [], terminals: [shell]), [
            SessionInfo.make("terminal", window: "terminal-window", state: .needsInput, cwd: "/tmp"),
        ]) == "1")
    }

    @Test func tabsWithoutARowAreNotCounted() {
        #expect(label(state(tasks: [task(windowId: "task-window")]), [
            SessionInfo.make("unknown", window: "elsewhere", task: UUID(), state: .needsInput, cwd: "/tmp"),
            SessionInfo.make("stray", window: "stray-window", state: .done, cwd: "/tmp"),
        ]) == nil)
    }

    /// A task on its way out is passed over, as Focus View passes over it.
    @Test func aTaskBeingRemovedIsNotCounted() {
        let leaving = task(windowId: "leaving-window")
        let tabs = [SessionInfo.make("leaving", window: "leaving-window", task: leaving.id, state: .needsInput, cwd: "/tmp")]
        #expect(label(state(tasks: [leaving]), tabs) == "1")
        #expect(label(state(tasks: [leaving]), tabs, skipping: [leaving.id]) == nil)
    }
}
