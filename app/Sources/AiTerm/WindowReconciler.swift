import Foundation
import AiTermCore

/// What the helper reports, kept in step with the workspace: the tabs and usage go to `live`, a
/// window iTerm2 raised selects its row, and a window iTerm2 no longer has — told by `window.closed`,
/// by a connected snapshot, or by a request that found it gone — leaves its task's row windowless and
/// takes a terminal's. Each task remembers the conversations its window's tabs show, which a reopen
/// resumes. When the person closes one task's window, Remove Task's own question follows a moment
/// later (`ClosedWindowTriage`): iTerm2 quitting, crashing or a restart closes windows too, and asks
/// nothing. A task whose removal has let its window go is the removal's to settle, and is left be.
@MainActor
final class WindowReconciler {
    private let workspace: WorkspaceStore
    private let work: WorkInFlight
    private let live: LiveSessions
    private let checkouts: CheckoutMonitor
    private let focus: RowFocus
    /// Asks Remove's question about a task whose window the person closed.
    private let remover: TaskRemover
    /// The time a close is held against: read when it arrives, when iTerm2 leaves the synced state
    /// and when its hold ends.
    private let now: @MainActor () -> ContinuousClock.Instant
    /// How long before a held close is looked at again: `ClosedWindowTriage.hold`, or none in a test,
    /// which moves `now` itself.
    private let closeHold: Duration
    /// Brings AiTerm forward for the question: the person was in iTerm2, closing its window.
    private let bringForward: @MainActor () -> Void
    /// The closes held so far; a test reads whether a close was held at all.
    private(set) var triage = ClosedWindowTriage()
    /// The latest held close's look, which waits for the looks before it: a test awaits this one.
    private(set) var settling: Task<Void, Never>?
    /// The latest question, which waits for the one before it to be answered and its removal done:
    /// one alert at a time.
    private(set) var asking: Task<Void, Never>?
    /// Moves on at each `stop()`: a look or a question armed before it — the latest, or one it waits
    /// on — sees it moved, and does nothing.
    private var epoch = 0

    init(helper: HelperLink, workspace: WorkspaceStore, work: WorkInFlight, live: LiveSessions, checkouts: CheckoutMonitor,
         focus: RowFocus, remover: TaskRemover, now: @escaping @MainActor () -> ContinuousClock.Instant, closeHold: Duration,
         bringForward: @escaping @MainActor () -> Void) {
        self.workspace = workspace
        self.work = work
        self.live = live
        self.checkouts = checkouts
        self.focus = focus
        self.remover = remover
        self.now = now
        self.closeHold = closeHold
        self.bringForward = bringForward
        helper.onEvent { [weak self] in self?.handle($0) }
        // Retries the checkout cleanup that waited for a daemon to close a window with.
        helper.onAttach { [weak checkouts] in checkouts?.refresh() }
        focus.onWindowGone { [weak self] in self?.handleWindowClosed($0) }
    }

    private var state: AppState { workspace.state }

    /// Quit: a held close is let go and a question still to come is never asked — nor the hold's look
    /// that would ask it. iTerm2 as it was is forgotten with them: after a later start, only the next
    /// connected snapshot makes a close one to ask about.
    func stop() {
        epoch += 1
        settling?.cancel()
        asking?.cancel()
        settling = nil
        asking = nil
        triage = ClosedWindowTriage()
    }

    /// The helper's events, after `helper` has taken its own.
    private func handle(_ event: DaemonEvent) {
        live.handle(event)
        switch event {
        case .snapshot(let snapshot):
            // A connected snapshot is iTerm2 as it is now: a close after it is one the daemon saw happen.
            triage.itermSynced(snapshot.connected, at: now())
            // The workspace as the snapshot shows it (`AppState.reconciled`), adopted in one change
            // by `commitClosedWindows` if anything differs. A task whose removal has let its window
            // go is the removal's to settle, and keeps no window the snapshot offers it.
            let lettingGo = Set(state.tasks.map(\.id).filter { work.operation(onTask: $0) == .removing(windowLetGo: true) })
            // ... and each task's conversations as its window shows them (`AppState.rememberingConversations`).
            let next = state.reconciled(with: snapshot, lettingGo: lettingGo).rememberingConversations(from: snapshot.sessions)
            guard next != state else { return }
            commitClosedWindows(next)
        case .itermConnected, .itermDisconnected, .itermAuthFailed:
            // Last observations remain visible while uncertain. Until the snapshot that follows, a
            // window reported closed may be one iTerm2 lost while it was away, which asks nothing.
            triage.itermSynced(false, at: now())
        case .itermCookieRequested: break
        case .windowActivated(let wid): focus.windowActivated(wid)
        case .windowClosed(let wid): windowClosedInIterm(wid)
        case .sessionOpened(let session), .sessionChanged(let session):
            // A tab naming a new conversation saves it with its task: what a reopen resumes.
            if let task = session.taskUUID {
                workspace.mutate { $0 = $0.rememberingConversations(from: live.sessions, only: [task]) }
            }
        case .sessionClosed, .usageChanged, .unknown: break // `live`'s, or nobody's
        }
    }

    /// A window gone — `window.closed`, or a request that found it gone: its task's row goes
    /// windowless, its terminal's row goes. Asks nothing: only `window.closed` can be a person's close.
    func handleWindowClosed(_ windowId: String?) {
        guard let windowId else { return }
        var next = state
        guard next.closeWindow(windowId) else { return }
        commitClosedWindows(next)
    }

    /// `window.closed`: the row loses its window at once, and a task's close is held before Remove's
    /// question is asked about it (`ClosedWindowTriage`). A close a removal or the checkout cleanup is
    /// making — anything running on the task — is theirs, and is held as a close of no task.
    private func windowClosedInIterm(_ windowId: String) {
        let closed = state.tasks.first { $0.windowId == windowId }?.id
        handleWindowClosed(windowId)
        triage.windowClosed(task: closed.flatMap { work.operation(onTask: $0) == nil ? $0 : nil }, at: now())
        guard triage.isHolding else { return }
        // Each close looks again once its own hold is over, after the looks armed before it: a close
        // whose hold ended before a later burst or disconnect is still due, and is asked about.
        let hold = closeHold, previous = settling, armed = epoch
        settling = Task { [weak self] in
            // Cancelled by `stop()`, at quit: the close is not looked at again.
            guard (try? await Task.sleep(for: hold)) != nil else { return }
            await previous?.value
            guard let self, epoch == armed else { return }
            askAboutHeldCloses()
        }
    }

    /// Every close that has waited out its hold with nothing after it: its task, if it is still there,
    /// windowless and free, is asked Remove Task's own question, one after another. A task with a tab
    /// still open in another window — its only tab dragged there, or the windows merged — lives on
    /// there: its row takes that window, and nothing is asked.
    private func askAboutHeldCloses() {
        for id in triage.due(at: now()) {
            let previous = asking, armed = epoch
            asking = Task { [weak self] in
                await previous?.value
                guard let self, epoch == armed, let task = state.task(id: id), task.windowId == nil,
                      work.operation(onTask: id) == nil else { return }
                if let window = live.window(ofTask: id) {
                    workspace.mutate { state in
                        if let i = state.tasks.firstIndex(where: { $0.id == id }) { state.tasks[i].windowId = window }
                    }
                    return
                }
                bringForward()
                await remover.confirmRemove(task: task)?.value
            }
        }
    }

    /// The one closed-window transition — for `window.closed`, a connected snapshot and a request
    /// that found its window gone: adopt the new workspace, whose change hooks drop a selection whose
    /// row went with it, and save. A task keeps its row, so nothing a checkout pass reads changes.
    private func commitClosedWindows(_ next: AppState) {
        workspace.mutate { $0 = next }
    }
}
