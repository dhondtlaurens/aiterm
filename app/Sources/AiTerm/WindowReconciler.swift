import Foundation
import AiTermCore

/// What the helper reports, kept in step with the workspace: the tabs and usage go to `live`, a
/// window iTerm2 raised selects its row, and a window iTerm2 no longer has leaves the row that had
/// it — told by `window.closed`, by a connected snapshot, or by a request that found it gone. A
/// task whose removal has let its window go is the removal's to settle, and is left be.
@MainActor
final class WindowReconciler {
    private let workspace: WorkspaceStore
    private let work: WorkInFlight
    private let live: LiveSessions
    private let checkouts: CheckoutMonitor
    private let focus: RowFocus

    init(helper: HelperLink, workspace: WorkspaceStore, work: WorkInFlight, live: LiveSessions, checkouts: CheckoutMonitor,
         focus: RowFocus) {
        self.workspace = workspace
        self.work = work
        self.live = live
        self.checkouts = checkouts
        self.focus = focus
        helper.onEvent { [weak self] in self?.handle($0) }
        // Retries the checkout cleanup that waited for a daemon to close a window with.
        helper.onAttach { [weak checkouts] in checkouts?.refresh() }
        focus.onWindowGone { [weak self] in self?.handleWindowClosed($0) }
    }

    private var state: AppState { workspace.state }

    /// The helper's events, after `helper` has taken its own.
    private func handle(_ event: DaemonEvent) {
        live.handle(event)
        switch event {
        case .snapshot(let snapshot):
            guard snapshot.connected else { return }
            // Only a successful connected snapshot establishes that a window is absent.
            // Reattach by stable task tags first, including a create whose reply was lost.
            // Worked on a copy, which `commitClosedWindows` adopts in one change if anything differs.
            var next = state
            let tabByTask = Dictionary(snapshot.sessions.compactMap { tab in tab.taskUUID.map { ($0, tab) } },
                                       uniquingKeysWith: { first, _ in first })
            // A task whose removal has let its window go is the removal's to settle: re-attached,
            // the window would take the row with it when it closes.
            for index in next.tasks.indices where work.operation(onTask: next.tasks[index].id) != .removing(windowLetGo: true) {
                if let session = tabByTask[next.tasks[index].id] { next.tasks[index].windowId = session.windowId }
            }
            let windows = Set(snapshot.sessions.map(\.windowId))
            let closed = Set((next.tasks.compactMap(\.windowId) + next.terminals.compactMap(\.windowId))
                .filter { !windows.contains($0) })
            for wid in closed { next.closeWindow(wid) }
            guard next != state else { return }
            commitClosedWindows(next)
        case .itermConnected, .itermDisconnected, .itermAuthFailed, .itermCookieRequested: break // last observations remain visible while uncertain
        case .windowActivated(let wid): focus.windowActivated(wid)
        case .windowClosed(let wid): handleWindowClosed(wid)
        case .sessionOpened, .sessionChanged, .sessionClosed, .usageChanged, .unknown: break // `live`'s, or nobody's
        }
    }

    func handleWindowClosed(_ windowId: String?) {
        guard let windowId else { return }
        var next = state
        guard next.closeWindow(windowId) else { return }
        commitClosedWindows(next)
    }

    /// The one closed-window transition — for `window.closed`, a connected snapshot and a request
    /// that found its window gone: adopt the new workspace — whose change hooks drop a selection
    /// whose row went with it — rescan checkouts when a task went, and save.
    private func commitClosedWindows(_ next: AppState) {
        let tasksRemoved = next.tasks.count != state.tasks.count
        workspace.mutate { $0 = next }
        if tasksRemoved { checkouts.refresh() }
    }
}
