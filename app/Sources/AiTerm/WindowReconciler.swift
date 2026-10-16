import Foundation
import AiTermCore

/// The rows and their iTerm2 windows, locked together. A row is what should be open, iTerm2 what is,
/// and each pass of `AppState.windowPlan` says what to do about the difference; only this owner acts
/// on it. A row takes back a window its tag is in; a window it is owed is opened again, its
/// conversations resumed, once iTerm2 is connected and a second has passed with no window closing; a
/// task's window the person closed alone gets Remove Task's own question a moment later — Cancel
/// brings it back, raised — and a terminal's takes its row (`ClosedWindowTriage`). iTerm2 quitting,
/// crashing or a restart closes windows too: those come back, quietly. A task whose removal has let
/// its window go is the removal's to settle, and is left be.
@MainActor
final class WindowReconciler {
    private let workspace: WorkspaceStore
    private let work: WorkInFlight
    private let live: LiveSessions
    private let checkouts: CheckoutMonitor
    private let focus: RowFocus
    /// Asks Remove's question about a task whose window the person closed.
    private let remover: TaskRemover
    /// Archives it instead, when the person answers Archive.
    private let archiver: TaskArchiver
    /// Opens a task's window: the one primitive creation and a restore share.
    private let launcher: TaskLauncher
    /// Opens a terminal's window: the one primitive a new terminal and a restore share.
    private let terminals: TerminalActions
    private let notices: Notices
    private let daemon: @MainActor () -> (any DaemonCommands)?
    /// The time a close is held against: read when it arrives, when iTerm2 leaves the synced state
    /// and when its hold ends.
    private let now: @MainActor () -> ContinuousClock.Instant
    /// How long before a close is looked at again: `ClosedWindowTriage.hold`, or none in a test,
    /// which moves `now` itself.
    private let closeHold: Duration
    /// Brings AiTerm forward for the question: the person was in iTerm2, closing its window.
    private let bringForward: @MainActor () -> Void
    /// Starts iTerm2 when a row is chosen while it is away: the person asking for it.
    private let launchIterm: @MainActor () -> Void
    /// The closes held so far, and whether iTerm2 has settled; a test reads whether a close was held.
    private(set) var triage = ClosedWindowTriage()
    /// The latest close's look, which waits for the looks before it: a test awaits this one.
    private(set) var settling: Task<Void, Never>?
    /// The latest question, which waits for the one before it to be answered and its removal done:
    /// one alert at a time.
    private(set) var asking: Task<Void, Never>?
    /// The latest restore, which waits for the one before it: windows come back one at a time, each
    /// tiled as a new one is. A test awaits this one.
    private(set) var lastRestore: Task<Void, Never>?
    /// Each row's restore while it runs: choosing the row meanwhile waits on it.
    private var restoring: [UUID: Task<Void, Never>] = [:]
    /// The tasks asked about, or waiting their turn: a question's row is not restored underneath it.
    private var questioned: Set<UUID> = []
    /// The rows whose restore failed and has not been tried again, which a pass leaves be.
    private var failed: Set<UUID> = []
    /// The tasks whose restore found their worktree gone before the checkout monitor read it so: left
    /// be until the monitor reads them again, rather than looked for at every pass meanwhile.
    private var worktreeGone: Set<UUID> = []
    /// `failed`, as each row reads it alone.
    private let failedRows: PerRow<Bool>
    /// Moves on at each `stop()`: a look or a question armed before it sees it moved, and does nothing.
    private var epoch = 0
    /// A pass is running, and another was asked for meanwhile: a pass's own work can start more.
    private var passing = false, passAgain = false

    init(helper: HelperLink, workspace: WorkspaceStore, work: WorkInFlight, live: LiveSessions, checkouts: CheckoutMonitor,
         focus: RowFocus, remover: TaskRemover,
         archiver: TaskArchiver, launcher: TaskLauncher, terminals: TerminalActions, notices: Notices,
         daemon: @escaping @MainActor () -> (any DaemonCommands)?, now: @escaping @MainActor () -> ContinuousClock.Instant,
         closeHold: Duration, bringForward: @escaping @MainActor () -> Void, launchIterm: @escaping @MainActor () -> Void) {
        self.workspace = workspace
        self.work = work
        self.live = live
        self.checkouts = checkouts
        self.focus = focus
        self.remover = remover
        self.archiver = archiver
        self.launcher = launcher
        self.terminals = terminals
        self.notices = notices
        self.daemon = daemon
        self.now = now
        self.closeHold = closeHold
        self.bringForward = bringForward
        self.launchIterm = launchIterm
        failedRows = PerRow(default: false, workspace: workspace)
        helper.onEvent { [weak self] in self?.handle($0) }
        // Retries the checkout cleanup that waited for a daemon to close a window with.
        helper.onAttach { [weak checkouts] in checkouts?.refresh() }
        focus.onWindowGone { [weak self] in self?.handleWindowClosed($0) }
        focus.onChoosingOwedRow { [weak self] in self?.choose($0) }
        // Work ending on a row — a removal kept, a restore done — can leave it owed and free.
        work.onChange { [weak self] _ in self?.pass() }
        // A worktree read missing, or back: a task whose restore found it gone has been read again.
        checkouts.onMissingChanged { [weak self] changed in
            guard let self, !worktreeGone.isDisjoint(with: changed) else { return }
            worktreeGone.subtract(changed)
            pass()
        }
    }

    private var state: AppState { workspace.state }

    /// Whether the row's last restore failed: its caption says so, and choosing it tries again.
    func hasFailed(_ id: UUID) -> Bool { failedRows[id] }

    /// Quit: a held close is let go and a question still to come is never asked — nor the look that
    /// would ask it. iTerm2 as it was is forgotten with them: after a later start, only the next
    /// connected snapshot makes a close one to ask about, or a row one to restore.
    func stop() {
        epoch += 1
        settling?.cancel()
        asking?.cancel()
        settling = nil
        asking = nil
        questioned = []
        triage = ClosedWindowTriage()
    }

    /// The helper's events, after `helper` has taken its own.
    private func handle(_ event: DaemonEvent) {
        live.handle(event)
        switch event {
        case .snapshot(let snapshot):
            // A connected snapshot is iTerm2 as it is now: a close after it is one the daemon saw happen.
            triage.itermSynced(snapshot.connected, at: now())
            // Each row whose window the snapshot lacks is owed it, and each task's conversations are
            // as its window shows them (`AppState.rememberingConversations`): what a restore resumes.
            let next = state.reconciled(with: snapshot).rememberingConversations(from: snapshot.sessions)
            if next != state { workspace.mutate { $0 = next } }
            pass()
        case .itermConnected, .itermDisconnected, .itermAuthFailed:
            // Last observations remain visible while uncertain. Until the snapshot that follows, a
            // window reported closed may be one iTerm2 lost while it was away, which asks nothing.
            triage.itermSynced(false, at: now())
        case .itermCookieRequested: break
        case .windowActivated(let wid): focus.windowActivated(wid)
        case .windowClosed(let wid): windowClosedInIterm(wid)
        case .sessionOpened(let session), .sessionChanged(let session):
            // A tab naming a new conversation saves it with its task: what a restore resumes. A tab
            // that moved to another window may hand its row that window.
            if let task = session.taskUUID {
                workspace.mutate { $0 = $0.rememberingConversations(from: live.sessions, only: [task]) }
            }
            pass()
        case .sessionClosed, .usageChanged, .operatorRequest, .unknown: break // `live`'s, the operators', or nobody's
        }
    }

    /// A window gone — `window.closed`, or a request that found it gone: its row is owed it. Asks
    /// nothing itself: only `window.closed` can be a person's close.
    func handleWindowClosed(_ windowId: String?) {
        guard let windowId else { return }
        var next = state
        guard next.closeWindow(windowId) else { return }
        workspace.mutate { $0 = next }
        pass()
    }

    /// `window.closed`: the row is owed its window at once, and the close is held a second
    /// (`ClosedWindowTriage`) before it is asked about — or, if iTerm2 was going away, restored. A
    /// close a removal, the checkout cleanup or Remove Terminal is making — work running on the row —
    /// is theirs, and is held as a close of no row.
    private func windowClosedInIterm(_ windowId: String) {
        let row = state.tasks.first { $0.windowId == windowId }?.id ?? state.terminals.first { $0.windowId == windowId }?.id
        triage.windowClosed(row: row.flatMap { isBusy($0) ? nil : $0 }, at: now())
        handleWindowClosed(windowId)
        // Each close looks again once its hold is over, after the looks armed before it: a lone close
        // is then due, and a burst's rows are free to come back once iTerm2 has stayed.
        let hold = closeHold, previous = settling, armed = epoch
        settling = Task { [weak self] in
            // Cancelled by `stop()`, at quit: the close is not looked at again.
            guard (try? await Task.sleep(for: hold)) != nil else { return }
            await previous?.value
            guard let self, epoch == armed else { return }
            pass()
        }
    }

    private func isBusy(_ id: UUID) -> Bool {
        work.operation(onTask: id) != nil || work.operation(onTerminal: id) != nil
    }

    /// One look at every row (`AppState.windowPlan`), and what it says done. Safe to ask for at any
    /// time: a pass asked for during one — its own restores start work, which asks — runs after it.
    func pass() {
        guard !passing else { passAgain = true; return }
        passing = true
        defer { passing = false }
        repeat {
            passAgain = false
            let state = self.state
            let rows = state.tasks.map(\.id) + state.terminals.map(\.id)
            // A failure is the row's: one that went takes its cell with it, and one whose row has a
            // window — adopted by tag, iTerm2's own restored one, a review opened into it — is over.
            let withWindow = Set(state.tasks.filter { $0.windowId != nil }.map(\.id)
                                 + state.terminals.filter { $0.windowId != nil }.map(\.id))
            let over = failed.filter { !rows.contains($0) || withWindow.contains($0) }
            for id in over { failedRows[id] = false }
            failed.subtract(over)
            worktreeGone.formIntersection(rows)
            let due = Set(triage.due(at: now()))
            // A removal stopped after its worktree went holds the row for the person's retry: there is
            // nothing left to open its window in.
            let awaitingRetry = state.tasks.map(\.id).filter { remover.removals[$0]?.awaitsRetry == true }
            let waiting = triage.held.union(questioned).union(restoring.keys).union(failed).union(awaitingRetry)
                .union(worktreeGone).union(rows.filter { isBusy($0) || checkouts.isMissing($0) })
            let lettingGo = Set(state.tasks.map(\.id).filter { work.operation(onTask: $0)?.letsWindowGo == true })
            let settled = workspace.canChangeWorkspace && daemon() != nil && triage.isQuiet(at: now())
            for step in state.windowPlan(sessions: live.sessions, settled: settled, due: due, waiting: waiting, lettingGo: lettingGo) {
                act(step)
            }
        } while passAgain
    }

    private func act(_ step: WindowStep) {
        switch step {
        case .adopt(let row, let window):
            workspace.mutate { state in
                switch row {
                case .task(let id): if let i = state.tasks.firstIndex(where: { $0.id == id }) { state.tasks[i].windowId = window }
                case .terminal(let id): if let i = state.terminals.firstIndex(where: { $0.id == id }) { state.terminals[i].windowId = window }
                }
            }
            // The row has its window now: a look again lets go of a failure it had.
            passAgain = true
        case .restore(let row): restore(row)
        case .ask(let id): ask(id)
        case .drop(let id): workspace.mutate { $0.terminals.removeAll { $0.id == id } }
        }
    }

    /// Remove Task's own question about a task whose window the person closed, with Archive as a third
    /// answer, one alert at a time. Remove removes it and Archive archives it, its window already gone;
    /// Cancel is the person keeping it, so the row is chosen as a click would — its window restored and
    /// raised.
    private func ask(_ id: UUID) {
        questioned.insert(id)
        let previous = asking, armed = epoch
        asking = Task { [weak self] in
            await previous?.value
            guard let self, epoch == armed else { return }
            defer { questioned.remove(id); pass() }
            guard let task = state.task(id: id), task.windowId == nil, work.operation(onTask: id) == nil else { return }
            bringForward()
            if let leaving = await remover.confirmRemove(task: task, archiveInstead: { [archiver] in await archiver.archive(task: $0) }) {
                await leaving.value
            } else if epoch == armed, state.task(id: id)?.windowId == nil {
                questioned.remove(id)
                focus.select(.task(id))
            }
        }
    }

    /// Opens the window `row` is owed, after the restore before it: a task's in its worktree with each
    /// remembered conversation resumed — the first in the window's own tab, each other in a tab of its
    /// own — a terminal's as a fresh shell in its project's folder. The row is busy meanwhile
    /// (`.reopening`). Nil when nothing starts: the row has a window, is busy, or no helper is there.
    /// Each looks again when its turn comes, behind the restores before it: AiTerm stopping, or iTerm2
    /// closing windows meanwhile — a quit under way — skips it without counting as a failure, and the
    /// next pass plans it again.
    @discardableResult
    func restore(_ row: WindowRow) -> Task<Void, Never>? {
        if let running = restoring[row.id] { return running }
        guard workspace.canChangeWorkspace, daemon() != nil else { return nil }
        let token: WorkInFlight.Token?
        switch row {
        case .task(let id):
            guard let task = state.task(id: id), task.windowId == nil else { return nil }
            token = work.begin(.reopening, onTask: id)
        case .terminal(let id):
            guard let terminal = state.terminal(id: id), terminal.windowId == nil else { return nil }
            token = work.begin(.reopening, onTerminal: id)
        }
        guard let token else { return nil }
        let previous = lastRestore, armed = epoch
        let running = Task {
            await previous?.value
            if epoch == armed, triage.isQuiet(at: now()), let daemon = self.daemon() { await open(row, with: daemon) }
            restoring[row.id] = nil
            work.end(token)
        }
        restoring[row.id] = running
        lastRestore = running
        return running
    }

    private func open(_ row: WindowRow, with daemon: any DaemonCommands) async {
        switch row {
        case .task(let id):
            guard let path = state.task(id: id)?.worktreePath else { return }
            // The checkout monitor reads a worktree gone only at its next pass: one gone before then has
            // nothing to open in, and waits for that pass, asked for now, to say so — not failed.
            guard await BackgroundWork.run({ FileManager.default.fileExists(atPath: path) }) else {
                worktreeGone.insert(id)
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
            } catch { fail(row, title: "Couldn’t reopen the window.", subject: id, error) }
        case .terminal(let id):
            guard let terminal = state.terminal(id: id), terminal.windowId == nil,
                  let project = state.project(id: terminal.projectId) else { return }
            do {
                let wid = try await terminals.openWindow(for: terminal, in: project, with: daemon)
                // A row that went meanwhile cannot adopt it, so the window is closed, not left behind.
                guard let i = state.terminals.firstIndex(where: { $0.id == id }) else {
                    try? await daemon.closeWindowIfOpen(wid)
                    return
                }
                workspace.mutate { $0.terminals[i].windowId = wid }
            } catch { fail(row, title: "Couldn’t reopen “\(terminal.name)”.", subject: nil, error) }
        }
    }

    /// A restore that failed while iTerm2 is still there: the row says so and waits for the person.
    /// One that failed because iTerm2 went away meanwhile is not the row's failure — the next
    /// connected snapshot restores it. The daemon's failed reply and its disconnect event race, so
    /// the reply saying iTerm2 is unavailable counts as much as the state not being synced.
    private func fail(_ row: WindowRow, title: String, subject: UUID?, _ error: Error) {
        guard triage.isSynced, (error as? DaemonError)?.code != .itermUnavailable else { return }
        failed.insert(row.id)
        failedRows[row.id] = true
        notices.report(OperationIssue(title: title, error: error, subject: subject))
    }

    /// A row chosen — a click or ↩ — whose window is owed: a restore under way is the answer again, so
    /// the choice raises the window it opens; one that failed is tried again. With iTerm2 away it is
    /// started, and the window comes back with the snapshot that follows. Nil when nothing opens now.
    private func choose(_ selection: RowSelection) -> Task<Void, Never>? {
        let row: WindowRow
        switch selection {
        case .task(let id): row = .task(id)
        case .terminal(let id): row = .terminal(id)
        case .project: return nil
        }
        if let running = restoring[row.id] { return running }
        if failed.remove(row.id) != nil { failedRows[row.id] = false }
        // The person asking for it looks for its worktree again.
        worktreeGone.remove(row.id)
        guard daemon() != nil else { notices.report(.disconnected("again")); return nil }
        guard triage.isSynced else { launchIterm(); return nil }
        pass()
        return restoring[row.id]
    }
}
