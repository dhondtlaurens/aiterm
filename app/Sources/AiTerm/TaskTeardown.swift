import Foundation
import AiTermCore

/// Takes tasks down: Archive, Remove, removing an archived row, and the closing of a task whose worktree went outside
/// AiTerm, which the checkout monitor reports (`CheckoutRemovals`).
///
/// Archive and Remove share one prepare (one `TaskWorkflow.preflight`, the folder git no longer lists, the worktree's
/// unsaved work) and one run: the window closed, and confirmed closed, before git deletes anything, then git's removal,
/// never forced unless agreed. A process still running in the window, a dev server's watcher, writes files back into a
/// checkout being deleted, and git then gives up halfway. Whether a teardown asks the person or refuses is its
/// `Consent`: the person's Archive and Remove ask; the Operator's Then refuses, and the reason it throws is what its
/// row says.
///
/// Archive saves the row into the archive before git removes the worktree, so a crash in between leaves an archived
/// row whose worktree still exists, which restore adopts, rather than a task whose checkout the cleanup would forget.
///
/// Each teardown holds its task in `WorkInFlight` while it runs (`.archiving`, `.removing`, `.closing`): that is the
/// task's lock and what its row says meanwhile. What a teardown leaves its row saying once it ends, a teardown that
/// stopped or a close to try again, is kept here until the task goes or is taken down again.
@MainActor
final class TaskTeardown: CheckoutRemovals {
    /// Whether a teardown may ask the person.
    enum Consent {
        /// Every question goes to the prompter. A failure is said on the row and in the banner, and nothing is thrown.
        case ask
        /// Nothing is asked. Anything that would ask, and every failed check, throws to the caller; nothing is said to
        /// the person and no row note is left. `stillAllowed` is the caller's say, read again after each wait.
        case refuse(stillAllowed: @MainActor () -> Bool)

        var refuses: Bool { if case .refuse = self { true } else { false } }
    }

    /// What Then throws when a worktree holds unsaved work: it is the person's to keep or lose.
    static let unsavedWork = "Not closed: its worktree has uncommitted or untracked files. Remove it yourself once they are safe."

    /// What the last teardown of a task left its row saying once it ended: why it stopped, or that its window is still
    /// to close. An entry goes with its task, or when a new teardown starts.
    private var left: [UUID: TaskRemoval] = [:] {
        didSet {
            for id in Set(oldValue.keys).union(left.keys) where oldValue[id] != left[id] { refresh(id) }
        }
    }
    /// Each row's state, observed row by row.
    private let rows: PerRow<TaskRemoval?>
    /// The tasks on their way out: their state is in progress. A task forgotten by its teardown stays here until the
    /// teardown's work ends.
    private(set) var leaving: Set<UUID> = []
    private let hooks = HookList<Void>()

    private let workspace: WorkspaceStore
    private let work: WorkInFlight
    private let workflow: TaskWorkflow
    private let notices: Notices
    private let prompter: Prompter
    private let checkouts: CheckoutMonitor
    private let live: LiveSessions
    private let daemon: @MainActor () -> (any DaemonCommands)?
    private let now: @MainActor () -> Date

    init(workspace: WorkspaceStore, work: WorkInFlight, workflow: TaskWorkflow, notices: Notices, prompter: Prompter,
         checkouts: CheckoutMonitor, live: LiveSessions, daemon: @escaping @MainActor () -> (any DaemonCommands)?,
         now: @escaping @MainActor () -> Date) {
        self.workspace = workspace
        self.work = work
        self.workflow = workflow
        self.notices = notices
        self.prompter = prompter
        self.checkouts = checkouts
        self.live = live
        self.daemon = daemon
        self.now = now
        rows = PerRow(default: nil, workspace: workspace)
        work.onChange { [weak self] subject in
            if case .task(let id) = subject { self?.refresh(id) }
        }
        notices.onWithdrawn { [weak self] in self?.clearStoppedNote(of: $0) }
        checkouts.removals = self
    }

    // -- the row's state ----------------------------------------------------------------
    /// Adds `hook` to what hears that a row's state changed.
    @discardableResult
    func onChanged(_ hook: @escaping @MainActor () -> Void) -> HookList<Void>.Token {
        hooks.add(hook)
    }

    /// The task's state, as its row draws it: the teardown running on it, or else what its last one left.
    func state(of id: UUID) -> TaskRemoval? { rows[id] }

    /// Whether the task is on its way out: its window is closing, or gone.
    func isLeaving(_ id: UUID) -> Bool { leaving.contains(id) }

    /// Whether the checkout monitor holds the task's diff still while its checkout goes.
    func removalInFlight(_ id: UUID) -> Bool { current(id)?.inProgress == true }

    #if DEBUG
    /// The snapshot renderer's rows mid-teardown, drawn without running one.
    func seedSnapshotState(_ state: TaskRemoval?, of id: UUID) { left[id] = state }
    #endif

    /// What a teardown left goes with its task: through a removed project, a restored backup or a removal. Runs on
    /// every change to the workspace, so it writes only what changed.
    func pruneStates() {
        guard !left.isEmpty else { return }
        let state = workspace.state
        let kept = left.filter { state.task(id: $0.key) != nil }
        if kept.count != left.count { left = kept }
    }

    /// The row's "Not removed" or "Not archived" note for task `id`, if its last teardown stopped. The note is the
    /// banner's twin: when the banner about the task goes, the task is a task again.
    func clearStoppedNote(of id: UUID) {
        if case .stopped? = left[id] { left[id] = nil }
    }

    private func current(_ id: UUID) -> TaskRemoval? { work.operation(onTask: id)?.removal ?? left[id] }

    private func refresh(_ id: UUID) {
        let now = current(id)
        guard rows[id] != now else { return }
        rows[id] = now
        if now?.inProgress == true { leaving.insert(id) } else { leaving.remove(id) }
        hooks()
    }

    // -- Archive ------------------------------------------------------------------------
    /// The worktree put away and the row into the archive; the branch is never touched. Returns once the archive has
    /// ended, or at once when nothing started: the workspace locked, the task gone, changed (refused) or busy.
    func archive(_ task: TaskItem, consent: Consent) async throws {
        let state = workspace.state
        guard workspace.canChangeWorkspace, let shown = state.task(id: task.id), !consent.refuses || shown == task,
              let project = state.project(id: shown.projectId), let token = work.begin(.archiving, onTask: task.id) else {
            if consent.refuses { throw ActionUnavailable("The task changed or is busy.") }
            return
        }
        defer { work.end(token) }
        left[task.id] = nil
        let id = task.id, kind = shown.kindName.lowercased()
        do {
            try await archiving(shown, in: project, consent: consent)
        } catch {
            guard !consent.refuses else { throw Self.refusal(error) }
            switch error {
            case Stop.kept: break
            case Stop.keptLate: left[id] = .stopped(note: "Not archived")
            case Stop.detached:
                await prompter.ask(AlertPrompt(
                    message: "“\(shown.title)” can’t be archived",
                    detail: "Its worktree isn’t on a branch, so its commits would be lost. Check out a branch, or remove the \(kind)."))
            case TeardownStop.noDaemon:
                left[id] = .stopped(note: "Not archived: iTerm2 isn’t connected")
                notices.report(OperationIssue(title: "Couldn’t archive the \(kind).", error: Self.noDaemon, subject: id))
            case TeardownStop.windowStayedOpen(let why):
                left[id] = .stopped(note: "Not archived: its window did not close")
                notices.report(OperationIssue(title: "Couldn’t archive the \(kind).", error: why, subject: id))
            default:
                left[id] = .stopped(note: "Not archived")
                notices.report(OperationIssue(title: "Couldn’t archive the \(kind).", error: error, subject: id))
            }
        }
    }

    private func archiving(_ task: TaskItem, in project: Project, consent: Consent) async throws {
        try requireIdle(task, consent)
        guard let prepared = try await prepare(task, in: project, verb: .archive, consent: consent) else { throw Stop.kept }
        let task = prepared.task
        // Under refusal: still allowed, and the row still in the project, folder and branch it was checked on.
        func unchanged() -> Bool {
            guard case .refuse(let stillAllowed) = consent, workspace.canChangeWorkspace, !Task.isCancelled, stillAllowed(),
                  let row = workspace.state.task(id: task.id) else { return false }
            return row.projectId == task.projectId && row.worktreePath == task.worktreePath && row.branch == task.branch
        }
        if consent.refuses {
            guard unchanged() else { throw ActionUnavailable("The stage changed while its worktree was checked.") }
            try requireIdle(task, consent)
        }
        try await closeWindow(of: task)
        // The branch it is on now: a task's worktree can have moved since it was created, or while its window closed.
        // Detached by now, its commits would go with the worktree, so it is refused, and the row stays a task without a
        // window until it is chosen. A folder gone by now is archived on the branch it had.
        let branch: String
        if consent.refuses {
            guard unchanged() else { throw ActionUnavailable("The stage changed while its window closed.") }
            let head = try await workflow.head(of: task, in: project)
            guard unchanged(), head == .missing || head == .branch(task.branch) else {
                throw ActionUnavailable("Its stage or branch changed while its window closed.")
            }
            try requireIdle(task, consent)
            branch = task.branch
        } else {
            switch try await workflow.head(of: task, in: project) {
            case .detached: throw Stop.detached
            case .branch(let name): branch = name
            case .missing: branch = if case .branch(let name) = prepared.head { name } else { task.branch }
            }
        }
        // On disk before the worktree goes (see the type's comment).
        workspace.mutate { $0.moveToArchive(taskId: task.id, branch: branch, at: now()) }
        guard workspace.flush() else {
            // Not on disk, so the worktree stays: deleted now, a crash before a save holds would bring back a task whose
            // checkout is gone, which the cleanup forgets. The row is a task again, without a window; the store is
            // failing, so it is not flushed again.
            workspace.mutate { $0.moveFromArchive(id: task.id) }
            throw ActionUnavailable(consent.refuses ? "Its archived row couldn’t be saved, so its checkout was kept."
                                                    : "Its place on the archive couldn’t be saved, so nothing was deleted.")
        }
        do {
            let archived: Void? = try await run(prepared, verb: .archive, consent: consent) { task, force in
                try await workflow.archive(task: task, project: project, force: force, allowUnlisted: prepared.allowUnlisted)
            }
            guard archived != nil else { throw Stop.keptLate }
        } catch {
            // Back in the sidebar, without a window until it is chosen.
            workspace.mutate { $0.moveFromArchive(id: task.id) }
            workspace.flush()
            throw error
        }
        checkouts.forget(task: task.id)
        checkouts.dropDiff(for: task.id)
        checkouts.refresh()
        if !consent.refuses, workspace.persistenceError == nil {
            notices.showToast("\(task.kindName) archived.", symbol: "tray.and.arrow.down")
        }
    }

    // -- Remove -------------------------------------------------------------------------
    /// The window, the worktree, the branch when asked for, then the row. Asked: the Remove alert first, whose box
    /// decides the branch; then the folder git no longer lists and the worktree's unsaved work, each of whose Keep ends
    /// the Remove with nothing changed; then, with "Delete local branch" ticked on a branch holding commits found
    /// nowhere else, whether to lose them. Only then does anything close or go. Refused: the branch is left alone, and
    /// a signal's is kept for Then to delete once merged.
    ///
    /// Each question is an `await`: a snapshot, a window closing or another Remove can run while it is up, and what
    /// follows an answer is decided on the row as it is then. Returns once the removal has ended, or at once when
    /// nothing started: the task gone or busy, the question declined, or another Remove took the task meanwhile.
    func remove(_ task: TaskItem, consent: Consent) async throws {
        switch consent {
        case .ask: await removeAsking(task)
        case .refuse(let stillAllowed): try await removeRefusing(task, stillAllowed: stillAllowed)
        }
    }

    private func removeAsking(_ task: TaskItem) async {
        let state = workspace.state
        guard workspace.canChangeWorkspace, work.operation(onTask: task.id) == nil, let shown = state.task(id: task.id),
              state.project(id: shown.projectId) != nil else { return }
        let detail = shown.kind == .review
            ? "Deletes its worktree and closes its iTerm2 window. Its local branch goes too, unless it has unpushed commits."
            : "Deletes its worktree and closes its iTerm2 window."
        let answer = await prompter.ask(.removeTask(shown, detail: detail))
        // Still needed after the await: a Remove started during the alert owns the removal now, and this answer then
        // does nothing; the task or its project can be gone, or the workspace locked.
        guard answer.confirmed, workspace.canChangeWorkspace, let current = workspace.state.task(id: task.id),
              let project = workspace.state.project(id: current.projectId),
              let token = work.begin(.removing, onTask: task.id) else { return }
        defer { work.end(token) }
        left[task.id] = nil
        do {
            guard let prepared = try await prepare(current, in: project, verb: .remove, consent: .ask),
                  let branch = await branchDeletion(of: prepared.task, in: project, asked: answer.checked) else { return }
            try await closeWindow(of: prepared.task)
            let removed = try await run(prepared, verb: .remove, consent: .ask) { task, force in
                try await workflow.remove(task: task, project: project, deleteBranch: branch.delete,
                                          discardingUnmerged: branch.discardingUnmerged, force: force,
                                          allowUnlisted: prepared.allowUnlisted)
            }
            guard let removed else { return }
            finishRemoval(of: task, after: removed)
        } catch {
            let title = "Couldn’t remove the \(task.kindName.lowercased())."
            switch error {
            case TeardownStop.noDaemon:
                left[task.id] = .stopped(note: "Not removed: iTerm2 isn’t connected")
                notices.report(OperationIssue(title: title, error: Self.noDaemon, subject: task.id))
            case TeardownStop.windowStayedOpen(let why):
                left[task.id] = .stopped(note: "Not removed: its window did not close")
                notices.report(OperationIssue(title: title, error: why, subject: task.id))
            default:
                left[task.id] = .stopped(note: "Not removed")
                notices.report(OperationIssue(title: title, error: error, subject: task.id))
            }
        }
    }

    private func removeRefusing(_ task: TaskItem, stillAllowed: @escaping @MainActor () -> Bool) async throws {
        guard workspace.canChangeWorkspace, workspace.state.task(id: task.id) == task,
              let project = workspace.state.project(id: task.projectId),
              let token = work.begin(.removing, onTask: task.id) else {
            throw ActionUnavailable("The task changed or is busy. Remove it yourself once it is safe.")
        }
        defer { work.end(token) }
        left[task.id] = nil
        let consent = Consent.refuse(stillAllowed: stillAllowed)
        do {
            try requireIdle(task, consent)
            _ = try await prepare(task, in: project, verb: .remove, consent: consent)
            guard let current = workspace.state.task(id: task.id), current.projectId == task.projectId,
                  current.worktreePath == task.worktreePath, current.branch == task.branch, current.baseBranch == task.baseBranch,
                  current.windowId == task.windowId, current.kind == task.kind,
                  current.signalTask?.stage == task.signalTask?.stage, current.signalTask?.ownership == task.signalTask?.ownership else {
                throw ActionUnavailable("The task changed while its worktree was checked.")
            }
            guard stillAllowed() else { throw ActionUnavailable("Its finished record couldn’t be saved, so nothing was removed.") }
            guard !task.workerTabs(in: live.sessions).contains(where: { $0.session.map { $0.windowId != task.windowId } == true }) else {
                throw ActionUnavailable("One of its tabs is outside its task window. Close it yourself, then retry Remove.")
            }
            try requireIdle(task, consent)
            try await closeWindow(of: task)
            let removed = try await run(.init(task: task, force: false, allowUnlisted: false, head: .missing),
                                        verb: .remove, consent: consent) { task, force in
                try await workflow.remove(task: task, project: project, deleteBranch: false, force: force,
                                          preserveBranch: task.isUnderOperator)
            }
            // A signal may have queued another stage while git removed the checkout. Keep the row and put its branch
            // back in a worktree before the new stage can continue.
            guard stillAllowed() else {
                _ = try await workflow.restore(task, project: project)
                throw ActionUnavailable("A new stage waits, so its checkout was restored and the task was kept.")
            }
            if let removed { finishRemoval(of: task, after: removed) }
            guard workspace.state.task(id: task.id) == nil, workspace.persistenceError == nil else {
                throw ActionUnavailable("Its removal could not be completed or saved.")
            }
        } catch {
            throw Self.refusal(error)
        }
    }

    /// What becomes of the branch once its row goes, `asked` being the alert's "Delete local branch". Asked for on a
    /// branch with commits found neither on its base nor on its upstream, or whose commits git could not place, the
    /// person decides first: Delete Branch loses them, Keep Branch (and ⎋) leaves the branch. Otherwise it goes by
    /// `TaskWorkflow.remove`'s own rule. Nil when the workspace locked while the question was up: nothing is removed
    /// then. One question for Remove and for removing an archived row.
    private func branchDeletion(of task: TaskItem, in project: Project, asked: Bool) async -> (delete: Bool, discardingUnmerged: Bool)? {
        guard asked else { return (false, false) }
        guard (try? await workflow.branchHasUnmergedCommits(of: task, in: project)) ?? true else { return (true, false) }
        let answer = await prompter.ask(.deleteUnmergedBranchQuestion(for: task))
        guard workspace.canChangeWorkspace else { return nil }
        return answer.confirmed ? (true, true) : (false, false)
    }

    /// The row goes once its window and worktree have, and the toast says what became of its branch when it was to go
    /// and was kept.
    private func finishRemoval(of task: TaskItem, after result: TaskWorkflow.Removed) {
        forget(task: task)
        if workspace.persistenceError == nil {
            notices.showRemoval(of: task, result: result)
        }
    }

    /// The row goes, and with it, through the workspace's change hooks, the banner about it, the selection if it was
    /// the row, and what its last teardown left. Saved at once: a removal says "removed" only once its row's going is
    /// on disk.
    private func forget(task: TaskItem) {
        workspace.mutate { $0.tasks.removeAll { $0.id == task.id } }
        workspace.flush()
        checkouts.forget(task: task.id)
        checkouts.refresh()
    }

    // -- removing an archived row -------------------------------------------------------
    /// Remove's own question about an archived row and, with "Delete local branch" ticked on a branch holding commits
    /// found nowhere else, Remove's question about losing them; then its record forgotten and, when asked for, its
    /// branch deleted, a review's released as Remove does. Its old worktree path is never touched: something else may
    /// live there by now. The row goes whatever git did with the branch, and the toast says when it was kept. Returns
    /// once the row is forgotten or the removal stopped, or at once when nothing started.
    func removeArchived(_ id: UUID) async {
        guard workspace.canChangeWorkspace, work.operation(onTask: id) == nil, let shown = workspace.state.archived(id: id)?.task,
              workspace.state.project(id: shown.projectId) != nil else { return }
        let answer = await prompter.ask(.removeTask(shown,
            detail: "Forgets it and its conversations. Its worktree was deleted when it was archived."
                + (shown.kind == .review ? " Its local branch goes too, unless it has unpushed commits." : "")))
        // As in Remove: what the answer finds is decided on the row as it is once the alert is gone.
        guard answer.confirmed, workspace.canChangeWorkspace, let task = workspace.state.archived(id: id)?.task,
              let project = workspace.state.project(id: task.projectId),
              let token = work.begin(.removing, onTask: id) else { return }
        defer { work.end(token) }
        guard let branch = await branchDeletion(of: task, in: project, asked: answer.checked) else { return }
        do {
            let result = try await workflow.forgetArchived(task: task, project: project, deleteBranch: branch.delete,
                                                           discardingUnmerged: branch.discardingUnmerged)
            workspace.mutate { $0.removeArchived(id: id) }
            workspace.flush()
            if workspace.persistenceError == nil {
                notices.showRemoval(of: task, result: result)
            }
        } catch {
            // No subject: a banner's subject names a sidebar row, and an archived one is not a row there, so a subject
            // would make `Notices` drop the banner as stale.
            notices.report(OperationIssue(title: "Couldn’t remove the \(task.kindName.lowercased()).", error: error))
        }
    }

    // -- checkouts removed outside AiTerm -----------------------------------------------
    /// The tasks a checkout pass found gone, as they are now. One being changed is its teardown's to finish. One whose
    /// agent removed its own worktree and is still finishing its turn waits: closing the window would kill it. The turn
    /// still ends: every harness AiTerm drives delivers its end of turn without a process in the removed checkout
    /// (Claude's HTTP hooks, Codex's `Stop` over MCP, PI's in-process extension; docs/status-model.md, “A turn that
    /// removes its own checkout”), and the next pass closes it.
    func forgetRemovedCheckouts(_ removed: [TaskItem]) {
        // A task still closing whose checkout came back is not closing any more.
        let gone = Set(removed.map(\.id))
        for (id, state) in left where state == .closing && !gone.contains(id) && work.operation(onTask: id) == nil {
            left[id] = nil
        }
        for task in removed where workspace.state.tasks.contains(task) && work.operation(onTask: task.id) == nil
            && !Self.turnInFlight(task.id, in: live) {
            close(task)
        }
    }

    /// The closing of a task whose checkout the scan confirmed gone: git's record of the checkout cleared, which its
    /// lock keeps (best effort; the row goes either way), its windows closed (the row's own and any its tabs were
    /// dragged into), then its row forgotten. The window keeps its row until it has closed: a failed close leaves the
    /// row saying "Closing…", and the next pass tries again, rather than flickering back to "Worktree missing" between
    /// tries. A row with any of those windows waits, saying nothing new, while iTerm2 is away, and while one of them
    /// holds other work (`holdsOtherWork`).
    private func close(_ task: TaskItem) {
        let windows = self.windows(of: task)
        if !windows.isEmpty, daemon() == nil { return }
        // A window holding other work would end that work too: the row stays as it is, its worktree missing, and each
        // pass leaves it so until that work has left.
        if holdsOtherWork(windows, own: task.windowId, of: task.id) { return }
        guard let token = work.begin(.closing, onTask: task.id) else { return }
        left[task.id] = nil
        let project = workspace.state.project(id: task.projectId)
        Task {
            defer { work.end(token) }
            if let project { await workflow.forgetDeletedCheckout(of: task, in: project) }
            for windowId in windows {
                guard let daemon = daemon(), (try? await daemon.closeWindowIfOpen(windowId)) != nil else {
                    left[task.id] = .closing
                    checkouts.dropDiff(for: task.id)
                    return
                }
            }
            // A newer window must not be forgotten by an old close. The close's own `window.closed` can arrive before
            // its answer and leave the row windowless: still this close's.
            guard let current = workspace.state.task(id: task.id), current.windowId == task.windowId || current.windowId == nil
            else { return }
            forget(task: task)
            notices.showToast("\(task.kindName) closed because its worktree was removed.")
        }
    }

    // -- the shared prepare and run -----------------------------------------------------
    /// The action the questions are worded for.
    private enum Verb {
        case remove, archive

        var name: String {
            switch self {
            case .remove: "Remove"
            case .archive: "Archive"
            }
        }
    }

    /// Why an archive ended without archiving, apart from the teardown's and git's refusals.
    private enum Stop: Error {
        /// Kept at the first questions: nothing moved, and the row says nothing.
        case kept
        /// Kept at git's late refusal: the row came back, and says so.
        case keptLate
        case detached
    }

    /// Why a teardown stopped before git deleted anything, told apart from git's refusals so the row can say which.
    private enum TeardownStop: Error {
        /// The window would not close, so nothing was deleted.
        case windowStayedOpen(ActionUnavailable)
        /// A row with a window found no helper to close it with, so nothing was deleted.
        case noDaemon
    }

    private static let noDaemon = ActionUnavailable("iTerm2 isn’t connected, so its window couldn’t close and nothing was deleted.")

    /// What the questions before a teardown agreed to: the row to take down, whether git may discard its unsaved work,
    /// and whether a folder git no longer lists may go.
    private struct Prepared {
        var task: TaskItem
        var force: Bool
        var allowUnlisted: Bool
        /// What the preflight read the worktree on, before any question.
        let head: WorktreeHead
    }

    /// The checks before anything closes, from one preflight (`TaskWorkflow.preflight`): a folder git no longer lists,
    /// the head, then unsaved work. Asked, a question answered Keep, a row gone or moved to another project or folder
    /// while it was up, or a locked workspace, gives nil; Archive's detached worktree is refused before anything is
    /// asked. Refused, each throws its reason.
    private func prepare(_ task: TaskItem, in project: Project, verb: Verb, consent: Consent) async throws -> Prepared? {
        let preflight = try await workflow.preflight(task: task, project: project)
        let unlisted = preflight.needsRemovalConfirmation
        var task = task
        switch consent {
        case .refuse:
            if unlisted {
                throw ActionUnavailable("Git no longer lists its folder. \(verb.name) it yourself once it is safe.")
            }
            if verb == .archive, preflight.head == .detached { throw ActionUnavailable("Its worktree is detached, so it was kept.") }
            if preflight.head != .missing, preflight.head != .branch(task.branch) {
                throw ActionUnavailable("Its worktree is no longer on its task branch.")
            }
        case .ask:
            if verb == .archive, preflight.head == .detached { throw Stop.detached }
            if unlisted {
                let answer = await prompter.ask(.unlistedFolderQuestion(for: task))
                guard answer.button == 1, let still = sameRow(as: task, in: project) else { return nil }
                task = still
            }
        }
        // Its own listing, right before git status: only it says the folder is still this repository's worktree now. A
        // worktree removed outside AiTerm since, its folder made again, is not. Unsaved work is what git status lists,
        // uncommitted or untracked changes; git-ignored files such as .env go with the worktree.
        var force = false
        if try await workflow.hasUnsavedWork(task: task, project: project) {
            if consent.refuses { throw ActionUnavailable(Self.unsavedWork) }
            guard await confirmDeletingUnsavedWork(of: task, verb: verb), let still = sameRow(as: task, in: project) else { return nil }
            task = still
            force = true
        }
        return Prepared(task: task, force: force, allowUnlisted: unlisted, head: preflight.head)
    }

    /// Git's part of the teardown, `force` as agreed, never forced otherwise. Unsaved work written after the questions,
    /// while the window closed, is git's to refuse: asked again then, and run forced on a yes with the row as it is now;
    /// nil when kept. Refused, it throws the unsaved-work reason.
    private func run<Result>(_ prepared: Prepared, verb: Verb, consent: Consent,
                             _ removal: (_ task: TaskItem, _ force: Bool) async throws -> Result) async throws -> Result? {
        do { return try await removal(prepared.task, prepared.force) }
        catch let error as GitError where error.refusedForUnsavedWork {
            if consent.refuses { throw ActionUnavailable(Self.unsavedWork) }
            guard await confirmDeletingUnsavedWork(of: prepared.task, verb: verb),
                  let project = workspace.state.project(id: prepared.task.projectId),
                  let task = sameRow(as: prepared.task, in: project) else { return nil }
            return try await removal(task, true)
        }
    }

    /// The row as it is now, sidebar or archive, while it is still in the same project and folder.
    private func sameRow(as task: TaskItem, in project: Project) -> TaskItem? {
        let state = workspace.state
        guard let row = state.task(id: task.id) ?? state.archived(id: task.id)?.task,
              row.projectId == project.id, row.worktreePath == task.worktreePath else { return nil }
        return row
    }

    /// Whether deleting the task's unsaved work is agreed to. False too when the workspace locked while the question
    /// was up.
    private func confirmDeletingUnsavedWork(of task: TaskItem, verb: Verb) async -> Bool {
        let answer = await prompter.ask(.unsavedWorkQuestion(for: task, archiving: verb == .archive))
        return answer.button == 1 && workspace.canChangeWorkspace
    }

    /// Closes every window the task holds now: the row's own, and each other window one of its tagged tabs is in, which
    /// the row would take once its own closed (`AppState.windowPlan`) and which would otherwise outlive the row and its
    /// worktree. The row drops its window first, so that window's own `window.closed` finds it windowless already; a
    /// row that takes another of them meanwhile holds a window this closes too. A window that will not close is given
    /// back, and nothing is deleted. A task with no window has nothing to close and needs no helper; one with a window
    /// and no helper to close it stops the teardown, as does a window holding another row's tab, or any tab not the
    /// task's in a window other than the row's own.
    private func closeWindow(of task: TaskItem) async throws {
        guard let i = workspace.state.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let windows = self.windows(of: workspace.state.tasks[i])
        guard !windows.isEmpty else { return }
        guard let daemon = daemon() else { throw TeardownStop.noDaemon }
        guard !holdsOtherWork(windows, own: workspace.state.tasks[i].windowId, of: task.id) else {
            throw ActionUnavailable("One of its tabs shares an iTerm2 window with other work. "
                                    + "Move that tab to its own window or close it, then try again.")
        }
        // Windowless at once, so the window's own `window.closed` finds it so; a snapshot no longer drops a row, so this
        // need not be on disk before the window closes.
        workspace.mutate { $0.tasks[i].windowId = nil }
        for wid in windows {
            do { try await daemon.closeWindowIfOpen(wid) }
            catch {
                if let j = workspace.state.tasks.firstIndex(where: { $0.id == task.id }), workspace.state.tasks[j].windowId == nil {
                    workspace.mutate { $0.tasks[j].windowId = wid }
                }
                throw TeardownStop.windowStayedOpen(ActionUnavailable("Its iTerm2 window did not close, so nothing was deleted. "
                                                                      + OperationIssue.reason(of: error)))
            }
        }
    }

    /// The row's own window, then every other window holding one of its tabs.
    private func windows(of task: TaskItem) -> [String] {
        var windows = task.windowId.map { [$0] } ?? []
        for tab in live.sessions where tab.taskUUID == task.id && !windows.contains(tab.windowId) { windows.append(tab.windowId) }
        return windows
    }

    /// Whether closing `windows` would close work that is not task `taskId`'s: a window closes with every tab in it, and a
    /// tab can be dragged between windows. The row's own window (`own`) may hold the person's plain tabs, as it always
    /// has, but no other row's; any other window holds only the task's.
    private func holdsOtherWork(_ windows: [String], own: String?, of taskId: UUID) -> Bool {
        live.sessions.contains { tab in
            guard windows.contains(tab.windowId), tab.taskUUID != taskId else { return false }
            return tab.windowId != own || tab.taskId != nil || tab.terminalId != nil
        }
    }

    // -- turns --------------------------------------------------------------------------
    /// Refused, a turn under way is waited for: the person driving a worker tab (`ClosingWait.turn`), or an agent
    /// mid-turn (`.agentTurn`). Checked first, so a task driven with edits waits rather than reads as unsaved work, and
    /// again after each wait, since a turn can start meanwhile. Asked, the person decides.
    private func requireIdle(_ task: TaskItem, _ consent: Consent) throws(ClosingWait) {
        guard consent.refuses else { return }
        guard !task.workerTabs(in: live.sessions).contains(where: { $0.session?.yourPrompt != nil }) else { throw .turn }
        guard !Self.turnInFlight(task.id, in: live) else { throw .agentTurn }
    }

    /// Whether any of the task's tabs has its agent mid-turn: working, or asking for input.
    private static func turnInFlight(_ taskId: UUID, in live: LiveSessions) -> Bool {
        live.sessions.contains { $0.taskUUID == taskId && ($0.state == .working || $0.state == .needsInput) }
    }

    /// A refusal in words the Operator's Then can say: a stop before git deleted anything is its own sentence.
    private static func refusal(_ error: any Error) -> any Error {
        switch error {
        case TeardownStop.noDaemon: ClosingWait.helper
        case TeardownStop.windowStayedOpen(let why): why
        default: error
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
