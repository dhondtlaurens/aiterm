import Foundation
import AiTermCore

/// Takes tasks out of the workspace: the person's Remove — every question first, then its window, its
/// worktree, its branch when asked for, and its row — and the closing of a task whose worktree went
/// outside AiTerm, which the checkout monitor reports (`CheckoutRemovals`).
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
    /// Each checkout the scan confirmed gone whose git record is being cleared
    /// (`TaskWorkflow.forgetDeletedCheckout`), at most one cleanup per task.
    private var recordCleanups: [UUID: Task<Void, Never>] = [:]

    private let workspace: WorkspaceStore
    private let work: WorkInFlight
    private let workflow: TaskWorkflow
    private let notices: Notices
    private let prompter: Prompter
    private let teardown: WorktreeTeardown
    private let checkouts: CheckoutMonitor
    private let live: LiveSessions
    private let daemon: @MainActor () -> (any DaemonCommands)?
    private let removalsHooks = HookList<Void>()

    init(workspace: WorkspaceStore, work: WorkInFlight, workflow: TaskWorkflow, notices: Notices, prompter: Prompter,
         teardown: WorktreeTeardown, checkouts: CheckoutMonitor, live: LiveSessions, daemon: @escaping @MainActor () -> (any DaemonCommands)?) {
        self.workspace = workspace
        self.work = work
        self.workflow = workflow
        self.notices = notices
        self.prompter = prompter
        self.teardown = teardown
        self.checkouts = checkouts
        self.live = live
        self.daemon = daemon
        rows = PerRow(default: nil, workspace: workspace)
        work.onChange { [weak self] subject in
            if case .task(let id) = subject { self?.refresh(id) }
        }
        notices.onWithdrawn { [weak self] in self?.clearStoppedNote(of: $0) }
        checkouts.removals = self
    }

    /// Adds `hook` to what hears that a row's removal changed: a task on its way out is not counted
    /// on the Dock.
    @discardableResult
    func onRemovalsChanged(_ hook: @escaping @MainActor () -> Void) -> HookList<Void>.Token {
        removalsHooks.add(hook)
    }

    /// The task's removal, as its row draws it.
    func removal(of id: UUID) -> TaskRemoval? { rows[id] }

    /// Whether the task's window is closing, or gone: its row is selected and nothing more.
    func isRemoving(_ id: UUID) -> Bool { removals[id]?.inProgress == true }

    /// The tasks on their way out, which Focus View and the Dock badge pass over: their windows are
    /// closing.
    var leavingTasks: Set<UUID> { Set(removals.filter(\.value.inProgress).keys) }

    /// Whether the checkout monitor holds the task's diff still while its checkout goes: something
    /// runs on the task.
    func removalInFlight(_ id: UUID) -> Bool {
        work.operation(onTask: id) != nil
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

    /// The row's "Not removed" note for task `id`, if its last removal or archive stopped. The note is
    /// the banner's twin: when the banner about the task goes, the task is a task again.
    func clearStoppedNote(of id: UUID) {
        if case .stopped? = outcomes[id] { outcomes[id] = nil }
    }

    /// What a stopped archive leaves the row saying. The row has one channel for why it is still
    /// here, a removal's or an archive's: the caption reads it, and the banner's going clears it.
    func recordStop(of id: UUID, note: String) { outcomes[id] = .stopped(note: note) }

    /// A new archive starting on the row: what the last one left it saying goes.
    func clearOutcome(of id: UUID) { outcomes[id] = nil }

    /// The row says what runs on it, and else what its last removal left.
    private func refresh(_ id: UUID) {
        let now = work.operation(onTask: id)?.removal ?? outcomes[id]
        guard removals[id] != now else { return }
        removals[id] = now
        rows[id] = now
        removalsHooks()
    }

    // -- the person's Remove ------------------------------------------------------------
    /// Whether the remove alert offers a "Delete local branch" checkbox. A review's branch is the
    /// merge request's — GitLab deletes it on merge — so it never does.
    ///
    /// This is the courtesy, not the guarantee: `TaskWorkflow.remove` refuses a review's branch
    /// deletion outright, so a caller that asks anyway still gets nothing. Hiding the
    /// checkbox here only keeps the alert from offering something that would be ignored.
    static func offersBranchDeletion(for task: TaskItem) -> Bool { task.kind != .review }

    /// Every question first, then the removal in one go. The Remove alert; the folder git no longer
    /// lists and the worktree's unsaved work (`WorktreeTeardown.prepare`), each of whose Keep ends the
    /// Remove with nothing changed; then, with "Delete local branch" ticked on a branch holding
    /// commits found nowhere else, whether to lose them. Only then the window closes, the worktree
    /// goes, the branch is deleted or left, and the row goes.
    ///
    /// Each question is an `await`: a snapshot, a window closing or another Remove can run while it
    /// is up. What happens after an answer is decided on the task as it is then — `task` is the row's
    /// copy, as old as the click. Returns once the removal has ended, or at once when nothing
    /// started: the task was gone or busy, the question was declined, or another Remove took the
    /// task while it was up.
    func confirmRemove(task: TaskItem) async {
        let state = workspace.state
        guard workspace.canChangeWorkspace, work.operation(onTask: task.id) == nil, let shown = state.task(id: task.id),
              state.project(id: shown.projectId) != nil else { return }
        let detail = shown.kind == .review
            ? "Deletes its worktree and closes its iTerm2 window. Its local branch goes too, unless it has unpushed commits."
            : "Deletes its worktree and closes its iTerm2 window."
        let answer = await prompter.ask(.removeTask(shown, detail: detail))
        // Still needed after the await: a Remove started during the alert owns the removal now, and
        // this answer then does nothing; the task or its project can be gone, or the workspace locked.
        guard answer.confirmed, workspace.canChangeWorkspace, let current = workspace.state.task(id: task.id),
              let project = workspace.state.project(id: current.projectId),
              let token = work.begin(.removing, onTask: task.id) else { return }
        outcomes[task.id] = nil
        defer { work.end(token) }
        do {
            guard let prepared = try await teardown.prepare(current, in: project, verb: .remove) else { return }
            guard let branch = await branchDeletion(of: prepared.task, in: project, asked: answer.checked) else { return }
            try await teardown.closeWindow(of: prepared.task)
            // Unsaved work written since its question is git's to refuse: asked again, kept on Keep.
            let removed = try await teardown.run(prepared, verb: .remove, current: { [workspace] in workspace.state.task(id: $0.id) }) {
                task, force in
                try await workflow.remove(task: task, project: project, deleteBranch: branch.delete,
                                          discardingUnmerged: branch.discardingUnmerged, force: force,
                                          allowUnlisted: prepared.allowUnlisted)
            }
            guard let removed else { return }
            finishRemoval(of: task, after: removed)
        } catch TeardownStop.noDaemon {
            outcomes[task.id] = .stopped(note: "Not removed: iTerm2 isn’t connected")
            notices.report(OperationIssue(title: "Couldn’t remove the \(task.kindName.lowercased()).",
                                          error: ActionUnavailable("iTerm2 isn’t connected, so its window couldn’t close and nothing was deleted."),
                                          subject: task.id))
        } catch TeardownStop.windowStayedOpen(let why) {
            outcomes[task.id] = .stopped(note: "Not removed: its window did not close")
            notices.report(OperationIssue(title: "Couldn’t remove the \(task.kindName.lowercased()).", error: why, subject: task.id))
        } catch {
            outcomes[task.id] = .stopped(note: "Not removed")
            notices.report(OperationIssue(title: "Couldn’t remove the \(task.kindName.lowercased()).", error: error, subject: task.id))
        }
    }

    /// What becomes of the branch once its row goes, `asked` being the alert's "Delete local branch".
    /// Asked for on a branch with commits found neither on its base nor on its upstream — or whose
    /// commits git could not place — the person decides first: Delete Branch loses them, Keep Branch
    /// (and ⎋) leaves the branch. Otherwise it goes by `TaskWorkflow.remove`'s own rule. Nil when the
    /// workspace locked while the question was up: nothing is removed then.
    /// One question for Remove and for removing an archived row.
    func branchDeletion(of task: TaskItem, in project: Project, asked: Bool) async -> (delete: Bool, discardingUnmerged: Bool)? {
        guard asked else { return (false, false) }
        guard (try? await workflow.branchHasUnmergedCommits(of: task, in: project)) ?? true else { return (true, false) }
        let answer = await prompter.ask(Self.deleteUnmergedBranchQuestion(for: task))
        guard workspace.canChangeWorkspace else { return nil }
        return answer.confirmed ? (true, true) : (false, false)
    }

    /// AiTerm's own Remove (Auto-close): no questions and no permission to discard changes. `starting` writes the
    /// task's finished record once nothing is left to keep the task, just before its window closes; false stops it.
    /// The caller records why cleanup stopped or what it waits for, and deletes a merged branch once the row is gone.
    func removeAutomatically(_ task: TaskItem, starting: @MainActor () -> Bool,
                             stillAllowed: @MainActor () -> Bool = { true }) async throws {
        guard workspace.canChangeWorkspace, let current = workspace.state.task(id: task.id), current == task,
              let project = workspace.state.project(id: task.projectId),
              let token = work.begin(.removing, onTask: task.id) else {
            throw ActionUnavailable("The task changed or is busy. Remove it yourself once it is safe.")
        }
        defer { work.end(token) }
        outcomes[task.id] = nil
        // A turn under way is waited for: checked first, so a task you are driving with edits waits rather than reads as
        // unsaved work, and again after the worktree checks, since a turn can start while they run.
        func waitForTurns() throws(ClosingWait) { try requireIdleForAutomaticCleanup(task) }
        try waitForTurns()
        // Unsaved work is what git status lists, uncommitted or untracked changes. Git-ignored files such as .env
        // are not: they go with the worktree, as with the person's Remove (plain git worktree remove, never forced).
        if try await workflow.hasUnsavedWork(task: task, project: project) {
            throw ActionUnavailable(AutomaticCleanup.unsavedWork)
        }
        if await hasWorktreeFolder(task) {
            guard try await workflow.head(of: task, in: project) == .branch(task.branch) else {
                throw ActionUnavailable("Its worktree is no longer on its task branch.")
            }
        }
        guard let current = workspace.state.task(id: task.id), current.projectId == task.projectId,
              current.worktreePath == task.worktreePath, current.branch == task.branch, current.baseBranch == task.baseBranch,
              current.windowId == task.windowId, current.kind == task.kind,
              current.signalTask?.stage == task.signalTask?.stage, current.signalTask?.ownership == task.signalTask?.ownership,
              current.signalTask?.takenOver == task.signalTask?.takenOver else {
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
            try await teardown.closeWindow(of: task)
        } catch TeardownStop.noDaemon {
            throw ClosingWait.helper
        }
        // Never forced, so changes made while the window closed are git's to refuse.
        let removed: TaskWorkflow.Removed
        do { removed = try await workflow.remove(task: task, project: project, deleteBranch: false, force: false,
                                                 preserveBranch: task.signalTask != nil) }
        catch let error as GitError where error.refusedForUnsavedWork { throw ActionUnavailable(AutomaticCleanup.unsavedWork) }
        // A signal may have queued another stage while git removed the checkout. Keep the
        // row and put its branch back in a worktree before the new stage can continue.
        guard stillAllowed() else {
            _ = try await workflow.restore(task, project: project)
            throw ActionUnavailable("A new stage waits, so its checkout was restored and the task was kept.")
        }
        finishRemoval(of: task, after: removed)
        guard workspace.state.task(id: task.id) == nil, workspace.persistenceError == nil else {
            throw ActionUnavailable("Its removal could not be completed or saved.")
        }
    }

    func requireIdleForAutomaticCleanup(_ task: TaskItem) throws(ClosingWait) {
        guard !AutomaticCleanup.isDriving(task, in: live) else { throw .turn }
        guard !Self.turnInFlight(task.id, in: live) else { throw .agentTurn }
    }

    /// Whether the task's worktree folder is there (`FolderCheck`).
    private func hasWorktreeFolder(_ task: TaskItem) async -> Bool {
        guard task.hasCheckout else { return false }
        return await FolderCheck.exists(task.worktreePath)
    }

    /// The question before a branch with commits its base lacks is deleted, which deletes them too.
    /// Delete Branch is the red default; Keep Branch answers ⎋ and still removes the row.
    static func deleteUnmergedBranchQuestion(for task: TaskItem) -> AlertPrompt {
        let base = task.baseBranch.isEmpty ? "its base" : task.baseBranch
        return AlertPrompt(
            message: "Delete branch \(task.branch)?",
            detail: "It has commits that aren’t on \(base). Deleting the branch deletes them too.",
            buttons: ["Delete Branch", "Keep Branch"], defaultDeletes: true, escape: 1)
    }

    /// The question before a folder git no longer lists is deleted: it may hold files AiTerm did not
    /// make. Keep is the default and ⎋. One wording for Remove and Archive.
    static func unlistedFolderQuestion(for task: TaskItem) -> AlertPrompt {
        AlertPrompt(message: "Delete the unlisted folder for “\(task.title)”?",
                    detail: "Git no longer lists this folder as a worktree. It may contain files AiTerm did not create.\n\(task.worktreePath)",
                    buttons: ["Keep", "Delete Folder"], escape: 0)
    }

    /// The row goes once its window and worktree have, and the toast says what became of its branch
    /// when it was to go and was kept.
    private func finishRemoval(of task: TaskItem, after result: TaskWorkflow.Removed) {
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

    // -- checkouts removed outside AiTerm ---------------------------------------------------
    /// The tasks a checkout pass found gone, as they are now: one being changed is its workflow's to
    /// finish. One whose agent removed its own worktree and is
    /// still finishing its turn waits: closing the window would kill it. The turn still ends: every
    /// harness AiTerm drives delivers its end of turn without a process in the removed checkout
    /// (Claude's HTTP hooks, Codex's `Stop` over MCP, PI's in-process extension; docs/status-model.md,
    /// “A turn that removes its own checkout”), and the next pass closes it.
    ///
    /// The scan confirms the checkout is gone. The main actor checks the task is unchanged and
    /// ready for cleanup, then closes it. Git's record of the checkout, which its lock keeps,
    /// is cleared beside the closing.
    func forgetRemovedCheckouts(_ removed: [TaskItem]) {
        // A task still closing whose checkout came back is not closing any more.
        let gone = Set(removed.map(\.id))
        for (id, outcome) in outcomes where outcome == .closing && !gone.contains(id) && work.operation(onTask: id) == nil {
            outcomes[id] = nil
        }
        for task in removed where awaitsCleanup(task) {
            if let project = workspace.state.project(id: task.projectId), recordCleanups[task.id] == nil {
                let workflow = workflow
                recordCleanups[task.id] = Task {
                    defer { recordCleanups[task.id] = nil }
                    await workflow.forgetDeletedCheckout(of: task, in: project)
                }
            }
            automaticallyForgetRemovedTask(task.id)
        }
    }

    /// Whether a task the pass found gone is the cleanup's to close: unchanged since, nothing else
    /// running on it, and its agent not mid-turn.
    private func awaitsCleanup(_ task: TaskItem) -> Bool {
        workspace.state.tasks.contains(task) && work.operation(onTask: task.id) == nil
            && !Self.turnInFlight(task.id, in: live)
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
        Task {
            defer { work.end(token) }
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
    }
}

extension DaemonCommands {
    /// Closes a window, treating one that is already gone as closed.
    func closeWindowIfOpen(_ windowId: String) async throws {
        do { try await close(windowId: windowId) }
        catch let error as DaemonError where error.isNotFound { }
    }
}
