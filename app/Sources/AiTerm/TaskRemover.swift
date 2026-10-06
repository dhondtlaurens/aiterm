import Foundation
import AiTermCore

/// A task on its way out, as its row says it: removed by the person — its window, its worktree,
/// maybe its branch — or closing because its worktree went outside AiTerm; or a removal that
/// stopped short of the row, and why. It is the row's own, so the banner above the list can come
/// and go — replaced by another report, or dismissed — without the row forgetting where it stands.
enum TaskRemoval: Equatable {
    case removing, closing
    /// What the row says in place of its "Window closed" or "Worktree missing". `worktreeRemoved`
    /// is a removal that got past the worktree: the row waits for the person's retry, and checkout
    /// cleanup, which would forget a row whose checkout went, leaves it be.
    case stopped(note: String, worktreeRemoved: Bool)

    /// Still running: the row's window is closing, or gone.
    var inProgress: Bool {
        if case .stopped = self { false } else { true }
    }

    /// Stopped after its worktree went, so the row is held for a retry.
    var awaitsRetry: Bool {
        if case .stopped(_, true) = self { true } else { false }
    }
}

/// Takes tasks out of the workspace: the person's Remove — its window, its worktree, its branch when
/// asked for, then its row, and the retries a removal that stopped short offers — and the closing of
/// a task whose worktree went outside AiTerm, which the checkout monitor reports.
///
/// Each removal holds its task in `WorkInFlight` while it runs, as `.removing` or `.closing`: that
/// is the task's lock, what its row says meanwhile, and whether a snapshot may give the task back a
/// window the removal has let go. What a removal leaves the row saying once it ends — a removal that
/// stopped, a close to try again — is kept here, until the task goes or is removed again.
@MainActor
final class TaskRemover {
    /// What each task's row says about its removal: the work running on it, or else what its last
    /// removal left. Kept whole for whatever reads it whole — the Dock badge, the checkout monitor,
    /// the tests — and mirrored row by row into `rows`, which the rows read.
    ///
    /// An entry can outlive its row for a moment: a removal forgets the row and then ends its work,
    /// so the task reads `.removing` or `.closing` here until the token ends. That is what keeps the
    /// Dock badge from counting the task once more in between; `pruneRemovals` drops only what a
    /// removal left, never the work running.
    private(set) var removals: [UUID: TaskRemoval] = [:]
    /// What the last removal of a task left its row saying once it ended: why it stopped, or that
    /// its window is still to close. An entry goes with its task, or when a new removal starts.
    private var outcomes: [UUID: TaskRemoval] = [:] {
        didSet {
            for id in Set(oldValue.keys).union(outcomes.keys) where oldValue[id] != outcomes[id] { refresh(id) }
        }
    }
    /// `removals`, observed row by row.
    private let rows: PerRow<TaskRemoval?>
    /// Each task's removal or closing while it runs, for whoever awaits it.
    private var running: [UUID: Task<Void, Never>] = [:]
    /// Each removed checkout being confirmed gone again before it is acted on: one at a time per task,
    /// so passes over a mount that has stopped answering do not pile up threads stuck on it.
    private var confirmations: [UUID: Task<Void, Never>] = [:]
    /// Whether a task's checkout is gone for good, asked off the main actor just before the cleanup
    /// acts on it.
    private let confirmsRemoval: ConfirmsRemoval

    private let workspace: WorkspaceStore
    private let work: WorkInFlight
    private let workflow: TaskWorkflow
    private let notices: Notices
    private let prompter: Prompter
    private let checkouts: CheckoutMonitor
    private let live: LiveSessions
    private let focus: RowFocus
    private let daemon: @MainActor () -> (any DaemonCommands)?
    /// Told whenever a row's removal changes: a task on its way out is not counted on the Dock.
    private let removalsChanged: @MainActor () -> Void

    /// Whether a task's checkout — at `projectPath`'s project, if it still has one — is gone for good.
    typealias ConfirmsRemoval = @Sendable (_ task: TaskItem, _ projectPath: String?) -> Bool

    /// The disk's answer to `ConfirmsRemoval`, which a test replaces with a mount that never answers.
    static let diskConfirmsRemoval: ConfirmsRemoval = { WorkspaceScan.checkoutRemovalIsConfirmed($0, projectPath: $1) }

    init(workspace: WorkspaceStore, work: WorkInFlight, workflow: TaskWorkflow, notices: Notices, prompter: Prompter,
         checkouts: CheckoutMonitor, live: LiveSessions, focus: RowFocus,
         daemon: @escaping @MainActor () -> (any DaemonCommands)?,
         confirmsRemoval: @escaping ConfirmsRemoval = TaskRemover.diskConfirmsRemoval,
         removalsChanged: @escaping @MainActor () -> Void) {
        self.workspace = workspace
        self.work = work
        self.workflow = workflow
        self.notices = notices
        self.prompter = prompter
        self.checkouts = checkouts
        self.live = live
        self.focus = focus
        self.daemon = daemon
        self.confirmsRemoval = confirmsRemoval
        self.removalsChanged = removalsChanged
        rows = PerRow(default: nil, workspace: workspace)
        work.onChange { [weak self] subject in
            if case .task(let id) = subject { self?.refresh(id) }
        }
    }

    /// The task's removal, as its row draws it.
    func removal(of id: UUID) -> TaskRemoval? { rows[id] }

    /// Whether the task's window is closing, or gone: its row is selected and nothing more.
    func isRemoving(_ id: UUID) -> Bool { removals[id]?.inProgress == true }

    /// The tasks on their way out, which Focus View and the Dock badge pass over: their windows are
    /// closing.
    var leavingTasks: Set<UUID> { Set(removals.filter(\.value.inProgress).keys) }

    /// Whether the checkout monitor holds the task's diff still while its checkout goes: something
    /// runs on the task — its cleanup's confirmation among them — and it is not a row waiting on a
    /// retry.
    func removalInFlight(_ id: UUID) -> Bool {
        (work.operation(onTask: id) != nil || confirmations[id] != nil) && removals[id]?.awaitsRetry != true
    }

    /// Waits for the task's removal or closing under way, if there is one — and for a removed
    /// checkout's confirmation first, which the closing follows.
    func waitForRemoval(of id: UUID) async {
        await confirmations[id]?.value
        await running[id]?.value
    }

    #if DEBUG
    /// The snapshot renderer's rows mid-removal, drawn without running one.
    func seedSnapshotRemoval(_ removal: TaskRemoval?, of id: UUID) { outcomes[id] = removal }
    #endif

    /// A removal's entry goes with its task — through `window.closed`, a removed project, a restored
    /// backup or a removal. Runs on every change to the workspace, so it writes only what changed.
    func pruneRemovals() {
        guard !outcomes.isEmpty else { return }
        let state = workspace.state
        let kept = outcomes.filter { state.task(id: $0.key) != nil }
        if kept.count != outcomes.count { outcomes = kept }
    }

    /// The row's "Not removed" note for task `id`, if that removal stopped with nothing deleted. The
    /// note is the banner's twin: when the banner about the task goes, the task is a task again.
    func clearStoppedNote(of id: UUID) {
        if case .stopped(_, worktreeRemoved: false)? = outcomes[id] { outcomes[id] = nil }
    }

    /// The row says what runs on it, and else what its last removal left.
    private func refresh(_ id: UUID) {
        let now = work.operation(onTask: id)?.removal ?? outcomes[id]
        guard removals[id] != now else { return }
        removals[id] = now
        rows[id] = now
        removalsChanged()
    }

    // -- the person's Remove ------------------------------------------------------------
    /// Whether the remove alert offers an "Also delete branch" checkbox. A review's branch is the
    /// merge request's — GitLab deletes it on merge — so it never does.
    ///
    /// This is the courtesy, not the guarantee: `TaskWorkflow.remove` refuses a review's branch
    /// deletion outright (Task 6), so a caller that asks anyway still gets nothing. Hiding the
    /// checkbox here only keeps the alert from offering something that would be ignored.
    static func offersBranchDeletion(for task: TaskItem) -> Bool { task.kind != .review }

    /// Each alert here is a reentrancy point: `runModal` drains the main queue, so a snapshot, a
    /// window closing or another Remove can run while it is up. What happens after an answer is
    /// decided on the task as it is then — `task` is the row's copy, as old as the click.
    @discardableResult
    func confirmRemove(task: TaskItem) -> Task<Void, Never>? {
        let state = workspace.state
        guard workspace.canChangeWorkspace, work.operation(onTask: task.id) == nil, let shown = state.task(id: task.id),
              state.project(id: shown.projectId) != nil else { return nil }
        let answer = prompter.ask(AlertPrompt(
            message: "Remove \(shown.kind == .review ? "review" : "task") “\(shown.title)”?",
            detail: shown.kind == .review
                ? "Deletes the worktree and closes its iTerm2 window. Its local branch goes too, unless it has commits origin lacks:\n\n\(shown.worktreePath)"
                : "Deletes the worktree and closes its iTerm2 window:\n\n\(shown.worktreePath)",
            buttons: ["Remove", "Cancel"],
            checkbox: Self.offersBranchDeletion(for: shown) ? "Also delete branch \(shown.branch)" : nil,
            defaultDeletes: true))
        // A Remove started during the alert owns the removal now; this answer then does nothing.
        guard answer.confirmed, workspace.canChangeWorkspace, let current = workspace.state.task(id: task.id),
              let project = workspace.state.project(id: current.projectId),
              let token = work.begin(.removing(windowLetGo: false), onTask: task.id) else { return nil }
        return remove(current, from: project, deleteBranch: answer.checked, holding: token)
    }

    /// The banner's Keep: the removal that stopped with the branch kept finishes, the branch left.
    /// Nil when the task is gone or busy, or no longer waiting on a retry.
    func keepBranch(of id: UUID) -> Task<Void, Never>? {
        guard let (task, project, token) = heldForRetry(id) else { return nil }
        notices.clearIssue()
        return remove(task, from: project, deleteBranch: false, holding: token)
    }

    /// The banner's Delete: deleting drops commits no other branch has, so it asks first. Nil when
    /// the question was declined, or the task is gone, busy or no longer waiting on a retry.
    func deleteBranch(of id: UUID) -> Task<Void, Never>? {
        guard let shown = workspace.state.task(id: id) else { return nil }
        let base = shown.baseBranch.isEmpty ? "its base" : shown.baseBranch
        let answer = prompter.ask(AlertPrompt(
            message: "Delete branch \(shown.branch)?",
            detail: "It has commits that aren’t on \(base). Deleting the branch deletes them too.",
            buttons: ["Delete Branch", "Cancel"], defaultDeletes: true))
        // The alert is a reentrancy point: act on the task as it is once it is answered.
        guard answer.confirmed, let (task, project, token) = heldForRetry(id) else { return nil }
        notices.clearIssue()
        return remove(task, from: project, deleteBranch: true, holding: token) { [workflow] in
            try await workflow.deleteUnmergedBranch(of: task, in: project)
        }
    }

    /// The task and its project, the task now held for a removal's retry — only while its removal is
    /// still waiting on one.
    private func heldForRetry(_ id: UUID) -> (TaskItem, Project, WorkInFlight.Token)? {
        let state = workspace.state
        guard workspace.canChangeWorkspace, removals[id]?.awaitsRetry == true, let task = state.task(id: id),
              let project = state.project(id: task.projectId),
              let token = work.begin(.removing(windowLetGo: false), onTask: id) else { return nil }
        return (task, project, token)
    }

    /// The removal itself, for a task `token` holds: its window, its worktree, its branch when asked
    /// for, then its row. `before` runs first; if it throws, nothing else does. A removal that stops
    /// says why on the row, which keeps it until the task goes or is removed again.
    private func remove(_ task: TaskItem, from project: Project, deleteBranch: Bool, holding token: WorkInFlight.Token,
                        before: (() async throws -> Void)? = nil) -> Task<Void, Never> {
        outcomes[task.id] = nil
        let removal = Task {
            defer { end(token, of: task.id) }
            do {
                try await before?()
                // A canceled confirmation leaves the task as it was.
                guard let result = try await removeWorktree(task: task, project: project, deleteBranch: deleteBranch,
                                                            holding: token) else { return }
                await finishRemoval(of: task, after: result)
            } catch RemovalStop.keptWithoutWindow {
                outcomes[task.id] = .stopped(note: "Kept; choose Reopen Window", worktreeRemoved: false)
                notices.report(OperationIssue(title: "\(task.kindName) kept. Its window had already closed.", subject: task.id))
            } catch RemovalStop.windowStayedOpen(let why) {
                outcomes[task.id] = .stopped(note: "Not removed: its window did not close", worktreeRemoved: false)
                notices.report(OperationIssue(title: "Couldn’t remove the \(task.kindName.lowercased()).", error: why, subject: task.id))
            } catch {
                outcomes[task.id] = .stopped(note: "Not removed", worktreeRemoved: false)
                notices.report(OperationIssue(title: "Couldn’t remove the \(task.kindName.lowercased()).", error: error, subject: task.id))
            }
        }
        running[task.id] = removal
        return removal
    }

    /// The task's window, then its worktree and its branch when asked for, through `TaskWorkflow`. A
    /// worktree with uncommitted changes asks first, while the window is still open; nil means it
    /// was kept. Unsaved work written after that check is only found once the window has closed:
    /// kept then, the task has lost its window, and `RemovalStop.keptWithoutWindow` says so.
    private func removeWorktree(task: TaskItem, project: Project, deleteBranch: Bool,
                                holding token: WorkInFlight.Token) async throws -> TaskWorkflow.Removed? {
        var task = task, force = false
        if try await workflow.hasUnsavedWork(task: task, project: project) {
            guard let still = confirmDeletingUnsavedWork(of: task) else { return nil }
            task = still
            force = true
        }
        let closed = try await closeWindowBeforeRemoval(of: task, holding: token)
        do { return try await workflow.remove(task: task, project: project, deleteBranch: deleteBranch, force: force) }
        catch let error as GitError where error.refusedForUnsavedWork {
            // Written after the check, before the window closed.
            guard let still = confirmDeletingUnsavedWork(of: task) else {
                if closed { throw RemovalStop.keptWithoutWindow }
                return nil
            }
            return try await workflow.remove(task: still, project: project, deleteBranch: deleteBranch, force: true)
        }
    }

    /// The task as it is once deleting its unsaved work is agreed to; nil when it is kept. The task
    /// is still held, so no other removal started, but its row can have gone.
    ///
    /// Keeping is the default, on ↩ and ⎋ both; deleting is the plain grey button beside it, never
    /// marked red — the red default is for a button ↩ can press.
    private func confirmDeletingUnsavedWork(of task: TaskItem) -> TaskItem? {
        let force = prompter.ask(AlertPrompt(
            message: "The worktree has uncommitted changes",
            detail: "Removing this worktree permanently deletes its uncommitted changes and untracked files.",
            buttons: [task.kind == .review ? "Keep Review" : "Keep Task", "Delete Changes and Remove"], escape: 0))
        guard force.button == 1, workspace.canChangeWorkspace else { return nil }
        return workspace.state.task(id: task.id)
    }

    /// Closes the window the task has now, before git deletes its worktree: a process still running
    /// there — a dev server's watcher — writes files back into a checkout being deleted, and git then
    /// gives up halfway. The row drops the window first, so the window's own `window.closed` does
    /// not take the row with it: the row stays until the removal is done, or for a retry if it fails.
    /// A window that will not close is given back, and nothing is deleted. Without a daemon it is
    /// left open, and `finishRemoval` asks for it to be closed by hand. True once a window closed.
    private func closeWindowBeforeRemoval(of task: TaskItem, holding token: WorkInFlight.Token) async throws -> Bool {
        guard let daemon = daemon(), let i = workspace.state.tasks.firstIndex(where: { $0.id == task.id }),
              let wid = workspace.state.tasks[i].windowId else { return false }
        work.update(token, to: .removing(windowLetGo: true))
        // Saved windowless too, and at once rather than a moment later: a removal that fails from
        // here — or an app that dies before it ends — leaves a row to retry after a relaunch, rather
        // than one the next snapshot drops for its missing window while its worktree is still there.
        workspace.mutate { $0.tasks[i].windowId = nil }
        workspace.flush()
        do { try await daemon.closeWindowIfOpen(wid) }
        catch {
            work.update(token, to: .removing(windowLetGo: false))
            if let j = workspace.state.tasks.firstIndex(where: { $0.id == task.id }), workspace.state.tasks[j].windowId == nil {
                workspace.mutate { $0.tasks[j].windowId = wid }
            }
            throw RemovalStop.windowStayedOpen(ActionUnavailable("Its iTerm2 window did not close (\(error)), so nothing was deleted."))
        }
        return true
    }

    /// Why a removal stopped before git deleted anything, told apart from git's refusals so the row
    /// can say which it was.
    private enum RemovalStop: Error {
        /// `closeWindowBeforeRemoval`'s window would not close, so nothing was deleted.
        case windowStayedOpen(ActionUnavailable)
        /// Unsaved work turned up once the window had closed, and the person kept the task.
        case keptWithoutWindow
    }

    /// With the worktree gone: a branch left behind, or a window that would not close, leaves the
    /// row for a retry and says why; otherwise the row goes.
    private func finishRemoval(of task: TaskItem, after result: TaskWorkflow.Removed) async {
        if let refusal = result.branchRefusal {
            outcomes[task.id] = .stopped(note: "Not removed: branch kept", worktreeRemoved: true)
            notices.report(.branchKept(task.branch, of: task.id, because: refusal))
            return
        }
        // The window the task has now: the one it had at the click can have closed, or come back.
        if let wid = workspace.state.task(id: task.id)?.windowId {
            guard let daemon = daemon() else {
                outcomes[task.id] = .stopped(note: "Worktree removed; close its window, then retry", worktreeRemoved: true)
                checkouts.dropDiff(for: task.id)
                notices.report(OperationIssue(title: "Worktree removed. Close its iTerm2 window, then retry Remove \(task.kindName).", subject: task.id))
                return
            }
            do { try await daemon.closeWindowIfOpen(wid) }
            catch {
                outcomes[task.id] = .stopped(note: "Worktree removed; its window did not close", worktreeRemoved: true)
                checkouts.dropDiff(for: task.id)
                notices.report(OperationIssue(title: "Worktree removed. Couldn’t close its window. Retry Remove \(task.kindName).", error: error, subject: task.id))
                return
            }
        }
        forget(task: task)
        if workspace.persistenceError == nil {
            notices.showToast("\(task.kindName) removed." + (result.keptBranch.map { " " + $0.note(branch: task.branch) } ?? ""))
        }
    }

    /// The row goes, and with it — through the workspace's change hooks — the banner about it and
    /// what its last removal left. Saved at once: a removal says "removed" only once its row's going
    /// is on disk.
    private func forget(task: TaskItem) {
        workspace.mutate { $0.tasks.removeAll { $0.id == task.id } }
        workspace.flush()
        checkouts.forget(task: task.id)
        checkouts.refresh()
        focus.dropStale()
    }

    /// The task's removal or closing has ended: it no longer holds the task.
    private func end(_ token: WorkInFlight.Token, of id: UUID) {
        running[id] = nil
        work.end(token)
    }

    // -- checkouts removed outside AiTerm ---------------------------------------------------
    /// The tasks a checkout pass found gone, as they are now: one being changed, or waiting on a
    /// removal's retry, is its workflow's to finish, and one whose checkout or project came back
    /// while the pass ran stays. One whose agent is still mid-turn — it removed its own worktree
    /// and is finishing up — waits: closing the window would kill it. The daemon settles such a
    /// turn even when the agent's last hook cannot arrive (spec §10b), and the next pass closes it.
    ///
    /// Each removal is confirmed once more just before it is acted on — the checkout can have come
    /// back since the pass looked — and off the main actor: a `stat` on a mount that has stopped
    /// answering holds a thread of its own, not the sidebar. The task is then checked again as it
    /// is now, back on the main actor, and only a task that is still gone and still waiting is
    /// closed.
    func forgetRemovedCheckouts(_ removed: [TaskItem]) {
        // A task still closing whose checkout came back is not closing any more.
        let gone = Set(removed.map(\.id))
        for (id, outcome) in outcomes where outcome == .closing && !gone.contains(id) && work.operation(onTask: id) == nil {
            outcomes[id] = nil
        }
        for task in removed where awaitsCleanup(task) && confirmations[task.id] == nil {
            let confirms = confirmsRemoval, projectPath = workspace.state.project(id: task.projectId)?.path
            confirmations[task.id] = Task {
                defer { confirmations[task.id] = nil }
                let confirmed = await withCheckedContinuation { continuation in
                    Thread { continuation.resume(returning: confirms(task, projectPath)) }.start()
                }
                guard confirmed, awaitsCleanup(task) else { return }
                automaticallyForgetRemovedTask(task.id)
            }
        }
    }

    /// Whether a task the pass found gone is the cleanup's to close: unchanged since, nothing else
    /// running on it, not held for a removal's retry, and its agent not mid-turn.
    private func awaitsCleanup(_ task: TaskItem) -> Bool {
        workspace.state.tasks.contains(task) && work.operation(onTask: task.id) == nil
            && removals[task.id]?.awaitsRetry != true && !turnInFlight(task.id)
    }

    private func turnInFlight(_ taskId: UUID) -> Bool {
        live.sessions.contains { $0.taskUUID == taskId && ($0.state == .working || $0.state == .needsInput) }
    }

    /// Keep the window identity until closure succeeds; a missing daemon or failed
    /// request is retried on the next poll/reconnect instead of orphaning the window. The row says
    /// "Closing…" from the first try until the window closes or the checkout comes back — not
    /// flickering back to "Worktree missing" between tries while iTerm2 is away.
    private func automaticallyForgetRemovedTask(_ id: UUID) {
        guard let task = workspace.state.task(id: id), work.operation(onTask: id) == nil else { return }
        guard let windowId = task.windowId else {
            forget(task: task)
            notices.showToast("\(task.kindName) closed because its worktree was removed.")
            return
        }
        guard let daemon = daemon(), let token = work.begin(.closing, onTask: id) else { return }
        // The closing says so itself while it runs.
        outcomes[id] = nil
        let closing = Task {
            defer { end(token, of: id) }
            // On failure the saved task remains visible, still closing, and the next poll retries.
            guard (try? await daemon.closeWindowIfOpen(windowId)) != nil else {
                outcomes[id] = .closing
                checkouts.dropDiff(for: id)
                return
            }
            // A newer window association must not be forgotten by an old response.
            guard workspace.state.task(id: id)?.windowId == windowId else { return }
            forget(task: task)
            notices.showToast("\(task.kindName) closed because its worktree was removed.")
        }
        running[id] = closing
    }
}

extension DaemonCommands {
    /// Closes a window, treating one that is already gone as closed.
    func closeWindowIfOpen(_ windowId: String) async throws {
        do { try await close(windowId: windowId) }
        catch let error as DaemonError where error.isNotFound { }
    }
}
