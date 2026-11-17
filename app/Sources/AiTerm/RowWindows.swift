import Foundation
import AiTermCore

/// Every row's iTerm2 window, where a window is only a view of its row: a task's, a terminal's and the
/// Operator's chat. A window iTerm2 reports gone leaves its row without one, and nothing else changes;
/// a row takes a window its tag is in (`AppState.windowPlan`); and a chosen row without a window has it
/// opened by the opener its kind needs (`open(_:)`). Nothing opens by itself: not after a close, not
/// when iTerm2 or AiTerm restarts. The chat's window is the Operator's own to write while a handover
/// runs, and is left be then.
@MainActor
final class RowWindows {
    private let workspace: WorkspaceStore
    private let work: WorkInFlight
    private let live: LiveSessions
    private let checkouts: CheckoutMonitor
    /// Opens a task's window: the one primitive creation and a chosen row share; and a taken-over task's.
    private let launcher: TaskLauncher
    /// Opens a terminal's window: the one primitive a new terminal and a chosen row share.
    private let terminals: TerminalActions
    /// Resumes a driven task's worker, and opens the Operator's chat.
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

    /// Opens a chosen row's window with the opener its kind needs: a task's in its worktree with each
    /// remembered conversation resumed — the first in the window's own tab, each other in a tab of its
    /// own — a taken-over task's through the launcher, a driven task's by resuming its worker, a
    /// terminal's as a fresh shell in its project's folder, and the Operator's chat through its
    /// controller. A second choose joins the open under way. Nil when nothing opens now: the row has a
    /// window, is gone, busy, a driven task not started yet, its worktree reads missing, the Operator has
    /// nothing to do, or no helper is there. With iTerm2 away it is started, and the row is handed to
    /// `onPendingOpen` once it is synced.
    @discardableResult
    func open(_ row: WindowRow) -> Task<Void, Never>? {
        if let running = opening[row] { return running }
        switch row {
        case .task(let id): guard let task = state.task(id: id), task.windowId == nil else { return nil }
        case .terminal(let id): guard let terminal = state.terminal(id: id), terminal.windowId == nil else { return nil }
        case .operatorChat: guard state.operatorHasWork, state.operatorSession?.window == nil else { return nil }
        }
        guard let daemon = daemon() else { notices.report(.disconnected("again")); return nil }
        guard itermSynced else {
            launchIterm()
            pendingOpen = row
            return nil
        }
        switch row {
        case .task(let id):
            guard let task = state.task(id: id), !checkouts.isMissing(id) else { return nil }
            if let record = task.signalTask {
                if record.takenOver {
                    let opening = launcher.openTakenOverWindow(id, prepareRequest: signalController.native.prepareTakenOverRequest,
                                                               resume: signalController.native.takenOverResumeCommands)
                    return run(row) { await opening.value }
                }
                // Nothing to open yet: the Operator has not made its checkout.
                guard record.phase != .launching || task.hasCheckout else { return nil }
                return run(row) { [signalController, notices] in
                    do {
                        try await signalController.reopenWorker(id)
                        notices.dropIssues(about: id)
                    } catch {
                        notices.report(OperationIssue(title: "Couldn’t reopen the window.", error: error, subject: id))
                    }
                }
            }
            guard let token = work.begin(.reopening, onTask: id) else { return nil }
            return run(row, ending: token) { [self] in await open(task, with: daemon) }
        case .terminal(let id):
            guard let terminal = state.terminal(id: id), let token = work.begin(.reopening, onTerminal: id) else { return nil }
            return run(row, ending: token) { [self] in await open(terminal, with: daemon) }
        case .operatorChat:
            return run(row) { [signalController, notices] in
                do { try await signalController.openChat() }
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

    private func open(_ task: TaskItem, with daemon: any DaemonCommands) async {
        let id = task.id
        // The checkout monitor reads a worktree gone only at its next pass: one gone before then has
        // nothing to open in, and that pass, asked for now, says so on the row.
        guard await FolderCheck.exists(task.worktreePath) else {
            checkouts.refresh()
            return
        }
        guard let task = state.task(id: id), task.windowId == nil else { return }
        let commands = task.resumeCommands
        do {
            guard let wid = try await launcher.openWindow(for: task, command: commands.first, with: daemon) else { return }
            notices.dropIssues(about: id)
            for command in commands.dropFirst() {
                do { _ = try await daemon.createTab(windowId: wid, cwd: task.worktreePath, agentCommand: command) }
                catch {
                    notices.report(OperationIssue(title: "Reopened the window, but not every conversation.", error: error, subject: id))
                    break
                }
            }
        } catch {
            notices.report(OperationIssue(title: "Couldn’t reopen the window.", error: error, subject: id))
        }
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
