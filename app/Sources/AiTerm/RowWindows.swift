import Foundation
import AiTermCore

/// Every row's iTerm2 window, where a window is only a view of its row: a task's, a terminal's and the
/// Operator's chat. A window iTerm2 reports gone leaves its row without one, and nothing else changes;
/// a row takes a window its tag is in (`AppState.windowPlan`); and a chosen row without a window has it
/// opened by the opener its kind needs (`open(_:)`). Nothing opens by itself: not after a close, not
/// when iTerm2 or AiTerm restarts. The chat's window is the Operator's own to write while its lifecycle
/// changes (opening, closing, revoking), and is left be then.
@MainActor
final class RowWindows {
    private let workspace: WorkspaceStore
    private let work: WorkInFlight
    private let live: LiveSessions
    private let checkouts: CheckoutMonitor
    /// Opens a task's window, a manual or driven one's (`TaskLauncher.open`).
    private let launcher: TaskLauncher
    /// Opens a terminal's window: the one primitive a new terminal and a chosen row share.
    private let terminals: TerminalActions
    /// Opens the Operator's chat.
    private let signalController: SignalOperatorController
    private let notices: Notices
    private let daemon: @MainActor () -> (any DaemonCommands)?
    /// Starts iTerm2 when a row is chosen while it is away: the person asking for it.
    private let launchIterm: @MainActor () -> Void
    /// Each row's open while it runs: choosing the row meanwhile joins it.
    private var opening: [WindowRow: Task<Void, Never>] = [:]
    /// The tabs as the last pass read them, where they are and which row each belongs to (`LiveSessions.rowSessions`): a
    /// session event that leaves them as they were has nothing for a pass to find.
    private var passedSessions: [SessionInfo]?
    /// Whether a connected snapshot has come since iTerm2 was last out of reach: until one has, the
    /// rows' windows are not known, and a chosen row waits for it.
    private(set) var itermSynced = false
    /// The row chosen while iTerm2 was not synced, handed to `pendingHooks` when it is.
    private var pendingOpen: WindowRow?
    private let pendingHooks = HookList<WindowRow>()

    init(helper: HelperLink, workspace: WorkspaceStore, work: WorkInFlight, live: LiveSessions, checkouts: CheckoutMonitor,
         focus: RowFocus, launcher: TaskLauncher, terminals: TerminalActions, signalController: SignalOperatorController,
         notices: Notices, daemon: @escaping @MainActor () -> (any DaemonCommands)?, launchIterm: @escaping @MainActor () -> Void) {
        self.workspace = workspace
        self.work = work
        self.live = live
        self.checkouts = checkouts
        self.launcher = launcher
        self.terminals = terminals
        self.signalController = signalController
        self.notices = notices
        self.daemon = daemon
        self.launchIterm = launchIterm
        helper.onEvent { [weak self] in self?.handle($0) }
        // Retries the checkout cleanup that waited for a daemon to close a window with.
        helper.onAttach { [weak checkouts] in checkouts?.refresh() }
        focus.onWindowGone { [weak self] in self?.windowGone($0) }
    }

    private var state: AppState { workspace.state }

    /// Adds `hook` to what hears, at the first connected snapshot, of the row chosen while iTerm2 was not
    /// synced: the app chooses it again if it is still the selection.
    @discardableResult
    func onPendingOpen(_ hook: @escaping @MainActor (WindowRow) -> Void) -> HookList<WindowRow>.Token {
        pendingHooks.add(hook)
    }

    /// Quit: iTerm2 as it was is forgotten, so after a later start a chosen row waits for the next
    /// connected snapshot.
    func stop() {
        itermSynced = false
    }

    /// The helper's events, after `helper` and the live sessions have taken theirs.
    private func handle(_ event: DaemonEvent) {
        switch event {
        case .snapshot(let snapshot):
            itermSynced = snapshot.connected
            // Each row whose window the snapshot lacks is left without one, and each task's conversations
            // are as its window shows them (`AppState.rememberingConversations`): what a later open resumes.
            let next = state.reconciled(with: snapshot).rememberingConversations(from: snapshot.sessions)
            if next != state { workspace.mutate { $0 = next } }
            pass()
            if snapshot.connected, let row = pendingOpen {
                pendingOpen = nil
                pendingHooks(row)
            }
        case .itermConnected, .itermDisconnected, .itermAuthFailed:
            // Until the snapshot that follows, the rows' windows are not known.
            itermSynced = false
        case .windowClosed(let wid): windowGone(wid)
        case .sessionOpened(let session), .sessionChanged(let session):
            // A tab naming a new conversation saves it with its task: what a later open resumes. A tab
            // that moved to another window may hand its row that window.
            if let task = session.taskUUID {
                workspace.mutate { $0 = $0.rememberingConversations(from: live.sessions, only: [task]) }
            }
            // A context fill, a model, a title: nothing a pass reads moved (`LiveSessions.rowSessions`).
            if live.rowSessions != passedSessions { pass() }
        case .itermCookieRequested, .windowActivated, .sessionClosed, .usageChanged, .operatorRequest, .unknown:
            break // the app's, `live`'s, the operators', or nobody's
        }
    }

    /// A window gone — `window.closed`, or a request that found it gone: its row is left without one,
    /// and takes at once another window its tag is in.
    func windowGone(_ windowId: String?) {
        guard let windowId else { return }
        var next = state
        guard next.closeWindow(windowId) else { return }
        workspace.mutate { $0 = next }
        pass()
    }

    /// Each row takes the window its tag is in (`AppState.windowPlan`).
    private func pass() {
        WorkMeter.note(.reconcilerPass)
        passedSessions = live.rowSessions
        for adoption in state.windowPlan(sessions: live.sessions) {
            workspace.mutate { state in
                switch adoption.row {
                case .task(let id):
                    if let i = state.tasks.firstIndex(where: { $0.id == id }) { state.tasks[i].windowId = adoption.windowId }
                case .terminal(let id):
                    if let i = state.terminals.firstIndex(where: { $0.id == id }) { state.terminals[i].windowId = adoption.windowId }
                case .operatorChat:
                    state.operatorSession?.window = adoption.windowId
                }
            }
        }
    }

    /// Opens a chosen row's window with the opener its kind needs: a task's, manual or driven, in its
    /// worktree with what its owner resumes (`TaskLauncher.open`), a terminal's as a fresh shell in its
    /// project's folder, and the Operator's chat through its controller. A second choose joins the open
    /// under way. Nil when nothing opens now: the row has a window, is gone, busy, a driven task not
    /// started yet, its worktree reads missing, the Operator has nothing to do, or no helper is there.
    /// With iTerm2 away it is started, whatever window the row last had (one iTerm2 lost by crashing is
    /// reported gone only once it is back), and the row is handed to `onPendingOpen` once it is synced.
    @discardableResult
    func open(_ row: WindowRow) -> Task<Void, Never>? {
        if let running = opening[row] { return running }
        let window: String?
        switch row {
        case .task(let id):
            guard let task = state.task(id: id) else { return nil }
            window = task.windowId
        case .terminal(let id):
            guard let terminal = state.terminal(id: id) else { return nil }
            window = terminal.windowId
        case .operatorChat:
            // With no work there is nothing to open, but a chat iTerm2 still shows is raised.
            window = state.operatorSession?.window
            guard state.operatorHasWork || window != nil else { return nil }
        }
        guard let daemon = daemon() else {
            if window == nil { notices.report(.disconnected("again")) }
            return nil
        }
        guard itermSynced else {
            launchIterm()
            pendingOpen = row
            return nil
        }
        guard window == nil else { return nil }
        switch row {
        case .task(let id):
            guard let task = state.task(id: id), !checkouts.isMissing(id) else { return nil }
            // Nothing to open yet: the Operator has not made its checkout.
            if task.signalTask?.phase == .launching, !task.hasCheckout { return nil }
            // A project signal's task still owing its first prompt opens through its pick-up, at once and with the prompt;
            // the chooser waits for it and raises the window it opened, as for any open.
            if let launching = signalController.projectSignals.choose(id) { return run(row) { await launching.value } }
            guard work.operation(onTask: id) == nil else { return nil }
            return run(row) { [launcher, notices] in
                do { try await launcher.open(id) }
                catch { notices.report(OperationIssue(title: "Couldn’t reopen the window.", error: error, subject: id)) }
            }
        case .terminal(let id):
            guard let terminal = state.terminal(id: id), let token = work.begin(.reopening, onTerminal: id) else { return nil }
            return run(row, ending: token) { [self] in await open(terminal, with: daemon) }
        case .operatorChat:
            return run(row) { [signalController, notices] in
                do { try await signalController.chat.open() }
                catch { notices.report(OperationIssue(title: "Couldn’t open the Operator’s chat.", error: error)) }
            }
        }
    }

    /// `body` as the row's open under way until it ends, and then the row's work `token` with it.
    private func run(_ row: WindowRow, ending token: WorkInFlight.Token? = nil,
                     _ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let running = Task {
            await body()
            opening[row] = nil
            if let token { work.end(token) }
        }
        opening[row] = running
        return running
    }

    private func open(_ terminal: TerminalItem, with daemon: any DaemonCommands) async {
        let id = terminal.id
        guard let terminal = state.terminal(id: id), terminal.windowId == nil,
              let project = state.project(id: terminal.projectId) else { return }
        do {
            guard try await terminals.openWindow(for: terminal, in: project, adding: false, with: daemon) != nil else { return }
            notices.dropIssues(about: id)
        } catch {
            notices.report(OperationIssue(title: "Couldn’t reopen “\(terminal.name)”.", error: error, subject: id))
        }
    }
}
