import Foundation
import AiTermCore

/// The rows and their iTerm2 windows, where a window is only a view of its row. A window iTerm2
/// reports gone leaves its row without one, and nothing else changes; a row takes a window its tag
/// is in (`AppState.windowPlan`); and a chosen row without a window has it opened, its conversations
/// resumed. Nothing opens by itself: not after a close, not when iTerm2 or AiTerm restarts.
@MainActor
final class WindowReconciler {
    private let workspace: WorkspaceStore
    private let work: WorkInFlight
    private let live: LiveSessions
    private let checkouts: CheckoutMonitor
    private let focus: RowFocus
    /// Opens a task's window: the one primitive creation and a chosen row share.
    private let launcher: TaskLauncher
    /// Opens a terminal's window: the one primitive a new terminal and a chosen row share.
    private let terminals: TerminalActions
    private let notices: Notices
    private let daemon: @MainActor () -> (any DaemonCommands)?
    /// Starts iTerm2 when a row is chosen while it is away: the person asking for it.
    private let launchIterm: @MainActor () -> Void
    /// Each row's open while it runs: choosing the row meanwhile joins it.
    private var opening: [UUID: Task<Void, Never>] = [:]
    /// The tabs as the last pass read them, where they are and which row each belongs to (`LiveSessions.rowSessions`): a
    /// session event that leaves them as they were has nothing for a pass to find.
    private var passedSessions: [SessionInfo]?
    /// Whether a connected snapshot has come since iTerm2 was last out of reach: until one has, the
    /// rows' windows are not known, and a chosen row waits for it.
    private(set) var itermSynced = false
    /// The row chosen while iTerm2 was not synced, chosen again when it is if it is still the selection.
    private var pendingOpen: WindowRow?

    init(helper: HelperLink, workspace: WorkspaceStore, work: WorkInFlight, live: LiveSessions, checkouts: CheckoutMonitor,
         focus: RowFocus, launcher: TaskLauncher, terminals: TerminalActions, notices: Notices,
         daemon: @escaping @MainActor () -> (any DaemonCommands)?, launchIterm: @escaping @MainActor () -> Void) {
        self.workspace = workspace
        self.work = work
        self.live = live
        self.checkouts = checkouts
        self.focus = focus
        self.launcher = launcher
        self.terminals = terminals
        self.notices = notices
        self.daemon = daemon
        self.launchIterm = launchIterm
        helper.onEvent { [weak self] in self?.handle($0) }
        // Retries the checkout cleanup that waited for a daemon to close a window with.
        helper.onAttach { [weak checkouts] in checkouts?.refresh() }
        focus.onWindowGone { [weak self] in self?.handleWindowClosed($0) }
        focus.setRestoreOwedRow { [weak self] selection in
            switch selection {
            case .task(let id): self?.open(.task(id))
            case .terminal(let id): self?.open(.terminal(id))
            case .project, .signal, .operation: nil
            }
        }
    }

    private var state: AppState { workspace.state }

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
            if snapshot.connected { openPending() }
        case .itermConnected, .itermDisconnected, .itermAuthFailed:
            // Until the snapshot that follows, the rows' windows are not known.
            itermSynced = false
        case .itermCookieRequested: break
        case .windowActivated(let wid): focus.windowActivated(wid)
        case .windowClosed(let wid): handleWindowClosed(wid)
        case .sessionOpened(let session), .sessionChanged(let session):
            // A tab naming a new conversation saves it with its task: what a later open resumes. A tab
            // that moved to another window may hand its row that window.
            if let task = session.taskUUID {
                workspace.mutate { $0 = $0.rememberingConversations(from: live.sessions, only: [task]) }
            }
            // A context fill, a model, a title: nothing a pass reads moved (`LiveSessions.rowSessions`).
            if live.rowSessions != passedSessions { pass() }
        case .sessionClosed, .usageChanged, .operatorRequest, .unknown: break // `live`'s, the operators', or nobody's
        }
    }

    /// A window gone — `window.closed`, or a request that found it gone: its row is left without one,
    /// and takes at once another window its tag is in.
    func handleWindowClosed(_ windowId: String?) {
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
                }
            }
        }
    }

    /// The row chosen while iTerm2 was away, now that it is synced: chosen again if it is still the
    /// selection, so its window opens and is raised as a click's is; dropped otherwise.
    private func openPending() {
        guard let row = pendingOpen else { return }
        pendingOpen = nil
        let selection: RowSelection = switch row {
        case .task(let id): .task(id)
        case .terminal(let id): .terminal(id)
        }
        guard focus.selection == selection else { return }
        focus.select(selection)
    }

    /// Opens a chosen row's window: a task's in its worktree with each remembered conversation resumed
    /// — the first in the window's own tab, each other in a tab of its own — a terminal's as a fresh
    /// shell in its project's folder. The row is busy meanwhile (`.reopening`), and a second choose
    /// joins the open under way. Nil when nothing opens now: the row has a window, is gone, busy or
    /// driven, its worktree reads missing, or no helper is there. With iTerm2 away it is started, and
    /// the row is chosen again once it is synced.
    @discardableResult
    func open(_ row: WindowRow) -> Task<Void, Never>? {
        if let running = opening[row.id] { return running }
        let task: TaskItem?, terminal: TerminalItem?
        switch row {
        case .task(let id):
            guard let found = state.task(id: id), found.windowId == nil else { return nil }
            (task, terminal) = (found, nil)
        case .terminal(let id):
            guard let found = state.terminal(id: id), found.windowId == nil else { return nil }
            (task, terminal) = (nil, found)
        }
        guard let daemon = daemon() else { notices.report(.disconnected("again")); return nil }
        guard itermSynced else {
            launchIterm()
            pendingOpen = row
            return nil
        }
        let token: WorkInFlight.Token?
        if let task {
            // Driven and taken-over tasks open through their worker opener (`RowFocus`).
            guard task.signalTask == nil, !checkouts.isMissing(task.id) else { return nil }
            token = work.begin(.reopening, onTask: task.id)
        } else {
            token = work.begin(.reopening, onTerminal: row.id)
        }
        guard let token else { return nil }
        let running = Task {
            if let task { await open(task, with: daemon) } else if let terminal { await open(terminal, with: daemon) }
            opening[row.id] = nil
            work.end(token)
        }
        opening[row.id] = running
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
