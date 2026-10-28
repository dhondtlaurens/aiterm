import Foundation
import AiTermCore

/// Takes tasks out of the workspace: the person's Remove — its window, its worktree, its branch when
/// asked for, then its row, and the retries a removal that stopped short offers — and the closing of
/// a task whose worktree went outside AiTerm, which the checkout monitor reports (`CheckoutRemovals`).
///
/// Each removal holds its task in `WorkInFlight` while it runs, as `.removing` or `.closing`: that
/// is the task's lock, what its row says meanwhile, and whether a snapshot may give the task back a
/// window the removal has let go. What a removal leaves the row saying once it ends — a removal that
/// stopped, a close to try again — is kept here, until the task goes or is removed again.
@MainActor
final class TaskRemover: CheckoutRemovals {
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
    private let teardown: WorktreeTeardown
    private let checkouts: CheckoutMonitor
    private let live: LiveSessions
    private let daemon: @MainActor () -> (any DaemonCommands)?
    private var removalsHooks: [@MainActor () -> Void] = []

    /// Whether a task's checkout — at `projectPath`'s project, if it still has one — is gone for good.
    typealias ConfirmsRemoval = @Sendable (_ task: TaskItem, _ projectPath: String?) -> Bool

    /// The disk's answer to `ConfirmsRemoval`, which a test replaces with a mount that never answers.
    static let diskConfirmsRemoval: ConfirmsRemoval = { WorkspaceScan.checkoutRemovalIsConfirmed($0, projectPath: $1) }

    init(workspace: WorkspaceStore, work: WorkInFlight, workflow: TaskWorkflow, notices: Notices, prompter: Prompter,
         teardown: WorktreeTeardown, checkouts: CheckoutMonitor, live: LiveSessions, daemon: @escaping @MainActor () -> (any DaemonCommands)?,
         confirmsRemoval: @escaping ConfirmsRemoval) {
        self.workspace = workspace
        self.work = work
        self.workflow = workflow
        self.notices = notices
        self.prompter = prompter
        self.teardown = teardown
        self.checkouts = checkouts
        self.live = live
        self.daemon = daemon
        self.confirmsRemoval = confirmsRemoval
        rows = PerRow(default: nil, workspace: workspace)
        work.onChange { [weak self] subject in
            if case .task(let id) = subject { self?.refresh(id) }
        }
        notices.onWithdrawn { [weak self] in self?.clearStoppedNote(of: $0) }
        checkouts.removals = self
    }

    /// Adds `hook` to what hears that a row's removal changed: a task on its way out is not counted
    /// on the Dock.
    func onRemovalsChanged(_ hook: @escaping @MainActor () -> Void) {
        removalsHooks.append(hook)
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

    /// A removal's entry goes with its task — through a removed project, a restored backup or a
    /// removal. Runs on every change to the workspace, so it writes only what changed.
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

    /// What a stopped archive leaves the row saying. The row has one channel for why it is still
    /// here, a removal's or an archive's: the caption reads it, and the banner's going clears it.
    func recordStop(of id: UUID, note: String) { outcomes[id] = .stopped(note: note, worktreeRemoved: false) }

    /// A new archive starting on the row: what the last one left it saying goes.
    func clearOutcome(of id: UUID) { outcomes[id] = nil }

    /// The row says what runs on it, and else what its last removal left.
    private func refresh(_ id: UUID) {
        let now = work.operation(onTask: id)?.removal ?? outcomes[id]
        guard removals[id] != now else { return }
        removals[id] = now
        rows[id] = now
        for hook in removalsHooks { hook() }
    }

    // -- the person's Remove ------------------------------------------------------------
    /// Whether the remove alert offers a "Delete local branch" checkbox. A review's branch is the
    /// merge request's — GitLab deletes it on merge — so it never does.
    ///
    /// This is the courtesy, not the guarantee: `TaskWorkflow.remove` refuses a review's branch
    /// deletion outright, so a caller that asks anyway still gets nothing. Hiding the
    /// checkbox here only keeps the alert from offering something that would be ignored.
    static func offersBranchDeletion(for task: TaskItem) -> Bool { task.kind != .review }

    /// Archive offered beside Remove: the window-close question's third answer.
    typealias ArchiveInstead = @MainActor (TaskItem) async -> Task<Void, Never>?

    /// Each question here is an `await`: a snapshot, a window closing or another Remove can run
    /// while it is up. What happens after an answer is decided on the task as it is then — `task`
    /// is the row's copy, as old as the click. Nil when nothing started: the task was gone or busy,
    /// the question was declined, or another Remove took the task while it was up.
    ///
    /// With `archiveInstead` the question is Remove, Archive, Cancel, and Archive hands the row, as
    /// it is then, to that; without it — the menu's and ⌘⌫'s Remove — there are two buttons.
    @discardableResult
    func confirmRemove(task: TaskItem, archiveInstead: ArchiveInstead? = nil) async -> Task<Void, Never>? {
        let state = workspace.state
        guard workspace.canChangeWorkspace, work.operation(onTask: task.id) == nil, let shown = state.task(id: task.id),
              state.project(id: shown.projectId) != nil else { return nil }
        // Archive never deletes a branch, so beside it a review's branch sentence is Remove's alone.
        let detail = switch (shown.kind == .review, archiveInstead != nil) {
        case (true, true):
            "Deletes its worktree and closes its iTerm2 window. Shelve does too, but keeps it to restore later. "
                + "Remove also deletes its local branch, unless it has unpushed commits."
        case (true, false):
            "Deletes its worktree and closes its iTerm2 window. Its local branch goes too, unless it has unpushed commits."
        case (false, true):
            "Deletes its worktree and closes its iTerm2 window. Shelve does too, but keeps it to restore later."
        case (false, false):
            "Deletes its worktree and closes its iTerm2 window."
        }
        let answer = await prompter.ask(.removeTask(shown, detail: detail, offersArchive: archiveInstead != nil))
        // The archive checks the row, its project and the workspace itself, as it does from the menu.
        if let archiveInstead, answer.button == 1 {
            guard let current = workspace.state.task(id: task.id) else { return nil }
            return await archiveInstead(current)
        }
        // Still needed after the await: a Remove started during the alert owns the removal now, and
        // this answer then does nothing; the task or its project can be gone, or the workspace locked.
        guard answer.confirmed, workspace.canChangeWorkspace, let current = workspace.state.task(id: task.id),
              let project = workspace.state.project(id: current.projectId),
              let token = work.begin(.removing(windowLetGo: false), onTask: task.id) else { return nil }
        return remove(current, from: project, deleteBranch: answer.checked, holding: token)
    }

    /// AiTerm's own Remove (Auto-close): no questions and no permission to discard changes. `starting` writes the
    /// task's finished record once nothing is left to keep the task, just before its window closes; false stops it.
    /// Why it stopped is saved on the task for its card (`OperatedTask.keptReason`), or what it waits for when it is to be
    /// tried again (`closingWait`). The caller deletes a merged branch once the row is gone.
    func removeAutomatically(_ task: TaskItem, starting: @MainActor () -> Bool) async throws {
        guard workspace.canChangeWorkspace, let current = workspace.state.task(id: task.id), current == task,
              let project = workspace.state.project(id: task.projectId),
              let token = work.begin(.removing(windowLetGo: false), onTask: task.id) else {
            throw ActionUnavailable("The task changed or is busy. Remove it yourself once it is safe.")
        }
        defer { end(token, of: task.id) }
        outcomes[task.id] = nil
        // A turn under way is waited for: checked first, so a task you are driving with edits waits rather than reads as
        // unsaved work, and again after the worktree checks, since a turn can start while they run.
        func waitForTurns() throws(ClosingWait) {
            guard !TaskAutoCloser.isDriving(task, in: live) else { throw .turn }
            guard !Self.turnInFlight(task.id, in: live) else { throw .agentTurn }
        }
        do {
            try waitForTurns()
            // Unsaved work is what git status lists, uncommitted or untracked changes. Git-ignored files such as .env
            // are not: they go with the worktree, as with the person's Remove (plain git worktree remove, never forced).
            if try await workflow.hasUnsavedWork(task: task, project: project) {
                throw ActionUnavailable(TaskAutoCloser.unsavedWork)
            }
            if await hasWorktreeFolder(task) {
                guard try await workflow.head(of: task, in: project) == .branch(task.branch) else {
                    throw ActionUnavailable("Its worktree is no longer on its task branch.")
                }
            }
            guard workspace.state.task(id: task.id) == task else {
                throw ActionUnavailable("The task changed while its worktree was checked.")
            }
            try waitForTurns()
            guard !task.workerTabs(in: live.sessions).contains(where: {
                $0.session.map { $0.windowId != task.windowId } == true
            }) else {
                throw ActionUnavailable("One of its tabs is outside its task window. Close it yourself, then retry Remove.")
            }
            guard starting() else { throw ActionUnavailable("Its finished record couldn’t be saved, so nothing was removed.") }
            do {
                try await teardown.closeWindow(of: task, holding: token, requiringDaemon: true,
                                               operation: { .removing(windowLetGo: $0) })
            } catch TeardownStop.noDaemon {
                throw ClosingWait.helper
            }
            // Never forced, so changes made while the window closed are git's to refuse.
            let removed: TaskWorkflow.Removed
            do { removed = try await workflow.remove(task: task, project: project, deleteBranch: false, force: false) }
            catch let error as GitError where error.refusedForUnsavedWork { throw ActionUnavailable(TaskAutoCloser.unsavedWork) }
            await finishRemoval(of: task, after: removed)
            guard workspace.state.task(id: task.id) == nil, workspace.persistenceError == nil else {
                throw ActionUnavailable("Its removal could not be completed or saved.")
            }
        } catch let waiting as ClosingWait {
            workspace.mutate { $0.updateOperated(task.id) { $0.closingWait = waiting } }
            throw waiting
        } catch {
            // A removal that stopped after its worktree went has left the row its own note, with the retry the person's
            // Remove offers there; its card says the same.
            let reason = if case .stopped(let note, _)? = outcomes[task.id] {
                TaskAutoCloser.failureReason(ActionUnavailable(note))
            } else {
                TaskAutoCloser.failureReason(error)
            }
            workspace.mutate { $0.updateOperated(task.id) { $0.keptReason = reason; $0.closingWait = nil } }
            throw error
        }
    }

    /// Whether the task's worktree folder is there, asked on a thread of its own: a mount that stopped answering stalls
    /// that thread, not the app or the shared pool.
    private func hasWorktreeFolder(_ task: TaskItem) async -> Bool {
        guard task.hasCheckout else { return false }
        let path = task.worktreePath
        return await ThreadWork.run { FileManager.default.fileExists(atPath: path) }
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
    func deleteBranch(of id: UUID) async -> Task<Void, Never>? {
        guard let shown = workspace.state.task(id: id) else { return nil }
        let answer = await prompter.ask(Self.deleteUnmergedBranchQuestion(for: shown))
        // Act on the task as it is once the alert is answered: across the await, a Keep or another
        // Delete can have taken it, or its row gone.
        guard answer.confirmed, let (task, project, token) = heldForRetry(id) else { return nil }
        notices.clearIssue()
        return remove(task, from: project, deleteBranch: true, holding: token) { [workflow] in
            try await workflow.deleteUnmergedBranch(of: task, in: project)
        }
    }

    /// The question before a branch with commits its base lacks is deleted, which deletes them too.
    /// One wording for the banner's Delete and for removing an archived row.
    static func deleteUnmergedBranchQuestion(for task: TaskItem) -> AlertPrompt {
        let base = task.baseBranch.isEmpty ? "its base" : task.baseBranch
        return AlertPrompt(
            message: "Delete branch \(task.branch)?",
            detail: "It has commits that aren’t on \(base). Deleting the branch deletes them too.",
            buttons: ["Delete Branch", "Cancel"], defaultDeletes: true)
    }

    /// The question before a folder git no longer lists is deleted: it may hold files AiTerm did not
    /// make. Keep is the default and ⎋. One wording for Remove and Shelve.
    static func unlistedFolderQuestion(for task: TaskItem) -> AlertPrompt {
        AlertPrompt(message: "Delete the unlisted folder for “\(task.title)”?",
                    detail: "Git no longer lists this folder as a worktree. It may contain files AiTerm did not create.\n\(task.worktreePath)",
                    buttons: ["Keep", "Delete Folder"], escape: 0)
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
            } catch TeardownStop.windowStayedOpen(let why) {
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
    /// kept then, the task's window comes back. Without a daemon the window is left open, and
    /// `finishRemoval` asks for it to be closed by hand.
    private func removeWorktree(task: TaskItem, project: Project, deleteBranch: Bool,
                                holding token: WorkInFlight.Token) async throws -> TaskWorkflow.Removed? {
        var task = task, force = false
        let unlisted = try await workflow.needsRemovalConfirmation(task: task, project: project)
        if unlisted {
            let answer = await prompter.ask(Self.unlistedFolderQuestion(for: task))
            guard answer.button == 1, let still = workspace.state.task(id: task.id),
                  still.worktreePath == task.worktreePath, still.projectId == project.id else { return nil }
            task = still
        }
        if try await workflow.hasUnsavedWork(task: task, project: project) {
            guard await teardown.confirmDeletingUnsavedWork(of: task, verb: .remove), let still = workspace.state.task(id: task.id) else { return nil }
            task = still
            force = true
        }
        try await teardown.closeWindow(of: task, holding: token, requiringDaemon: false, operation: { .removing(windowLetGo: $0) })
        do { return try await workflow.remove(task: task, project: project, deleteBranch: deleteBranch, force: force, allowUnlisted: unlisted) }
        catch let error as GitError where error.refusedForUnsavedWork {
            // Written after the check, before the window closed. Kept, the task is a task again: its
            // window, if this removal closed it, is owed and comes back (`WindowReconciler`).
            guard await teardown.confirmDeletingUnsavedWork(of: task, verb: .remove), let still = workspace.state.task(id: task.id) else { return nil }
            return try await workflow.remove(task: still, project: project, deleteBranch: deleteBranch, force: true, allowUnlisted: unlisted)
        }
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
            notices.showRemoval(of: task, result: result)
        }
    }

    /// The row goes, and with it — through the workspace's change hooks — the banner about it, the
    /// selection if it was the row, and what its last removal left. Saved at once: a removal says
    /// "removed" only once its row's going is on disk.
    private func forget(task: TaskItem) {
        workspace.mutate { $0.tasks.removeAll { $0.id == task.id } }
        workspace.flush()
        checkouts.forget(task: task.id)
        checkouts.refresh()
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
    /// and is finishing up — waits: closing the window would kill it. The turn still ends: every
    /// harness AiTerm drives delivers its end of turn without a process in the removed checkout
    /// (Claude's HTTP hooks, Codex's `Stop` over MCP, PI's in-process extension; docs/status-model.md,
    /// “A turn that removes its own checkout”), and the next pass closes it.
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
                let confirmed = await ThreadWork.run { confirms(task, projectPath) }
                guard confirmed, awaitsCleanup(task) else { return }
                automaticallyForgetRemovedTask(task.id)
            }
        }
    }

    /// Whether a task the pass found gone is the cleanup's to close: unchanged since, nothing else
    /// running on it, not held for a removal's retry, and its agent not mid-turn.
    private func awaitsCleanup(_ task: TaskItem) -> Bool {
        workspace.state.tasks.contains(task) && work.operation(onTask: task.id) == nil
            && removals[task.id]?.awaitsRetry != true && !Self.turnInFlight(task.id, in: live)
    }

    /// Whether any of the task's tabs has its agent mid-turn: working, or asking for input. The checkout cleanup and
    /// Auto-close both wait for it.
    static func turnInFlight(_ taskId: UUID, in live: LiveSessions) -> Bool {
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
            // A newer window association must not be forgotten by an old response. The close's own
            // `window.closed` can arrive before its answer and leave the row windowless: still this close's.
            guard let current = workspace.state.task(id: id), current.windowId == windowId || current.windowId == nil else { return }
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
