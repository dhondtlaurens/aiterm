import Foundation
import AiTermCore

/// What the helper reports, kept in step with the workspace: the tabs and usage go to `live`, a
/// window iTerm2 raised selects its row, and a window iTerm2 no longer has leaves the row that had
/// it — told by `window.closed`, by a connected snapshot, or by a request that found it gone. A
/// task whose removal has let its window go is the removal's to settle, and is left be. Each task
/// remembers the conversations its window's tabs show, which a reopen resumes.
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
            // The workspace as the snapshot shows it (`AppState.reconciled`), adopted in one change
            // by `commitClosedWindows` if anything differs. A task whose removal has let its window
            // go is the removal's to settle, and keeps no window the snapshot offers it.
            let lettingGo = Set(state.tasks.map(\.id).filter { work.operation(onTask: $0) == .removing(windowLetGo: true) })
            // ... and each task's conversations as its window shows them (`AppState.rememberingConversations`).
            let next = state.reconciled(with: snapshot, lettingGo: lettingGo).rememberingConversations(from: snapshot.sessions)
            guard next != state else { return }
            commitClosedWindows(next)
        case .itermConnected, .itermDisconnected, .itermAuthFailed, .itermCookieRequested: break // last observations remain visible while uncertain
        case .windowActivated(let wid): focus.windowActivated(wid)
        case .windowClosed(let wid): handleWindowClosed(wid)
        case .sessionOpened(let session), .sessionChanged(let session):
            // A tab naming a new conversation saves it with its task: what a reopen resumes.
            if let task = session.taskUUID {
                workspace.mutate { $0 = $0.rememberingConversations(from: live.sessions, only: [task]) }
            }
        case .sessionClosed, .usageChanged, .unknown: break // `live`'s, or nobody's
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
