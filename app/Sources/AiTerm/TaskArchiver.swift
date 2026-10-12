import Foundation
import AiTermCore

/// Archives tasks and reviews, restores them, and removes them from the archive.
///
/// Archive puts the worktree away; the branch is never touched. The row is saved into the archive
/// before git removes the worktree, so a crash in between leaves an archived row whose worktree still
/// exists — which restore adopts — rather than a task whose checkout the cleanup would forget. Restore
/// recreates the worktree and puts the row back owed its window: the window lock reopens it and
/// resumes its conversations, as after a restart.
@MainActor
final class TaskArchiver {
    private let workspace: WorkspaceStore
    private let work: WorkInFlight
    private let workflow: TaskWorkflow
    private let notices: Notices
    private let prompter: Prompter
    private let checkouts: CheckoutMonitor
    private let remover: TaskRemover
    private let focus: RowFocus
    private let teardown: WorktreeTeardown
    private let now: @MainActor () -> Date
    /// Each row's archive, restore or removal while it runs, for whoever awaits it.
    private(set) var running: [UUID: Task<Void, Never>] = [:]

    init(workspace: WorkspaceStore, work: WorkInFlight, workflow: TaskWorkflow, notices: Notices, prompter: Prompter,
         checkouts: CheckoutMonitor, remover: TaskRemover, focus: RowFocus, teardown: WorktreeTeardown,
         now: @escaping @MainActor () -> Date) {
        self.workspace = workspace; self.work = work; self.workflow = workflow; self.notices = notices
        self.prompter = prompter; self.checkouts = checkouts; self.remover = remover; self.focus = focus
        self.teardown = teardown; self.now = now
    }

    /// Why an archive ended without archiving, apart from the teardown's and git's refusals.
    private enum Stop: Error {
        /// Kept at the first question: nothing moved, and the row says nothing.
        case kept
        /// Kept at git's late refusal: the row came back, and says so.
        case keptLate
        case detached
    }

    // -- archive ------------------------------------------------------------------------
    /// Nil when nothing started: the workspace locked, the task gone, already busy or waiting on its
    /// removal's retry.
    @discardableResult
    func archive(task: TaskItem) async -> Task<Void, Never>? {
        let state = workspace.state
        // A row whose Remove stopped after its worktree went waits on that retry: it has no worktree to
        // put away, and starting would clear the outcome that holds it.
        guard workspace.canChangeWorkspace, let shown = state.task(id: task.id), let project = state.project(id: shown.projectId),
              remover.removals[task.id]?.awaitsRetry != true,
              let token = work.begin(.archiving(windowLetGo: false), onTask: task.id) else { return nil }
        remover.clearOutcome(of: task.id)
        let id = task.id, kind = shown.kindName
        let job = Task {
            defer { running[id] = nil; work.end(token) }
            do { try await archive(shown, in: project, holding: token) }
            catch Stop.kept {}
            catch Stop.keptLate { remover.recordStop(of: id, note: "Not shelved") }
            catch Stop.detached {
                await prompter.ask(AlertPrompt(
                    message: "“\(shown.title)” can’t be shelved",
                    detail: "Its worktree isn’t on a branch, so its commits would be lost. Check out a branch, or remove the \(kind.lowercased())."))
            }
            catch TeardownStop.noDaemon {
                remover.recordStop(of: id, note: "Not shelved: iTerm2 isn’t connected")
                notices.report(OperationIssue(title: "Couldn’t shelve the \(kind.lowercased()).",
                                              error: ActionUnavailable("iTerm2 isn’t connected, so its window couldn’t close and nothing was deleted."),
                                              subject: id))
            }
            catch TeardownStop.windowStayedOpen(let why) {
                remover.recordStop(of: id, note: "Not shelved: its window did not close")
                notices.report(OperationIssue(title: "Couldn’t shelve the \(kind.lowercased()).", error: why, subject: id))
            }
            catch {
                remover.recordStop(of: id, note: "Not shelved")
                notices.report(OperationIssue(title: "Couldn’t shelve the \(kind.lowercased()).", error: error, subject: id))
            }
        }
        running[id] = job
        return job
    }

    private func archive(_ task: TaskItem, in project: Project, holding token: WorkInFlight.Token) async throws {
        // A detached worktree is refused before anything is asked or closed. Read again once the
        // window is closed (below): until then its agent can still move it.
        let head = try await workflow.head(of: task, in: project)
        if head == .detached { throw Stop.detached }
        var force = false
        if try await workflow.hasUnsavedWork(task: task, project: project) {
            guard await teardown.confirmDeletingUnsavedWork(of: task, verb: .archive),
                  workspace.state.task(id: task.id) != nil else { throw Stop.kept }
            force = true
        }
        try await teardown.closeWindow(of: task, holding: token, requiringDaemon: true, operation: { .archiving(windowLetGo: $0) })
        // The branch it is on now — a task's worktree can have moved since it was created, or while
        // the question was up and its window closing. Detached by now, its commits would go with the
        // worktree: refused, and the row stays a task owed its window, which the window lock reopens.
        // A folder gone by now is archived as it was before the window closed.
        let branch: String
        switch try await workflow.head(of: task, in: project) {
        case .detached: throw Stop.detached
        case .branch(let name): branch = name
        case .missing: branch = if case .branch(let name) = head { name } else { task.branch }
        }
        // On disk before the worktree goes (see the type's comment).
        workspace.mutate { $0.moveToArchive(taskId: task.id, branch: branch, at: now()) }
        guard workspace.flush() else {
            // Not on disk, so the worktree stays: deleted now, a crash before a save holds would bring
            // back a task whose checkout is gone, which the cleanup forgets. The row is a task again,
            // owed its window; the store is failing, so it is not flushed again.
            workspace.mutate { $0.moveFromArchive(id: task.id) }
            throw ActionUnavailable("Its place on the shelf couldn’t be saved, so nothing was deleted.")
        }
        do {
            do { try await workflow.archive(task: task, project: project, force: force) }
            catch let error as GitError where error.refusedForUnsavedWork {
                // Written after the check, before the window closed.
                guard await teardown.confirmDeletingUnsavedWork(of: task, verb: .archive) else { throw Stop.keptLate }
                try await workflow.archive(task: task, project: project, force: true)
            }
        } catch {
            // Back in the sidebar, owed its window, which the window lock brings back.
            workspace.mutate { $0.moveFromArchive(id: task.id) }
            workspace.flush()
            throw error
        }
        checkouts.forget(task: task.id)
        checkouts.dropDiff(for: task.id)
        checkouts.refresh()
        if workspace.persistenceError == nil { notices.showToast("\(task.kindName) shelved.", symbol: "tray.and.arrow.down") }
    }

    // -- restore ------------------------------------------------------------------------
    /// Archived row `id`'s worktree back at its own path, then the row back in the sidebar — saved —
    /// its project opened, and the row chosen as a click chooses it: the window lock reopens its
    /// window, resuming its conversations, and raises it. A refusal before the worktree is back says
    /// why and leaves the row archived; a window that then fails is the sidebar's "Couldn’t reopen".
    /// Nil when nothing started.
    @discardableResult
    func restore(_ id: UUID) -> Task<Void, Never>? {
        let state = workspace.state
        guard workspace.canChangeWorkspace, let entry = state.archived(id: id), let project = state.project(id: entry.task.projectId),
              let token = work.begin(.restoring, onTask: id) else { return nil }
        let job = Task {
            var holding: WorkInFlight.Token? = token
            defer { if let holding { work.end(holding) }; running[id] = nil }
            let made: TaskCreator.Made
            do { made = try await workflow.restore(entry.task, project: project) }
            catch {
                await prompter.ask(AlertPrompt(message: "“\(entry.task.title)” can’t be restored", detail: OperationIssue.reason(of: error)))
                return
            }
            // Its project cannot have gone — removing it waits for this — but the workspace can have locked.
            // Left archived then, its worktree is adopted by the next restore.
            guard workspace.canChangeWorkspace, workspace.state.archived(id: id) != nil,
                  workspace.state.project(id: project.id) != nil else { return }
            workspace.mutate { state in
                state.moveFromArchive(id: id)
                state.updateProject(id: project.id) { $0.collapsed = false }
            }
            // The checkout monitor forgot the row when it was archived, as it does a new row's before
            // its first pass.
            checkouts.refresh()
            workspace.flush()
            TaskLauncher.report(made.worktreeInclude, of: made.task, to: notices)
            // Free before it is chosen: the window lock leaves a busy row alone.
            work.end(token)
            holding = nil
            focus.select(.task(id))
            if workspace.persistenceError == nil { notices.showToast("\(entry.task.kindName) restored.", symbol: "tray.and.arrow.up") }
        }
        running[id] = job
        return job
    }

    // -- remove from the archive --------------------------------------------------------
    /// Remove's own question about an archived row, then its record forgotten and — when asked for —
    /// its branch deleted, a review's released as Remove does. Its old worktree path is never
    /// touched: something else may live there by now. A branch with commits its base lacks asks
    /// before it goes. Nil when nothing started.
    @discardableResult
    func confirmRemove(archived id: UUID) async -> Task<Void, Never>? {
        guard workspace.canChangeWorkspace, work.operation(onTask: id) == nil, let shown = workspace.state.archived(id: id)?.task,
              workspace.state.project(id: shown.projectId) != nil else { return nil }
        let offersBranch = TaskRemover.offersBranchDeletion(for: shown)
        let answer = await prompter.ask(AlertPrompt(
            message: "Remove \(shown.kind == .review ? "review" : "task") “\(shown.title)”?",
            detail: "Forgets it and its conversations. Its worktree was deleted when it was shelved."
                + (shown.kind == .review ? " Its local branch goes too, unless it has unpushed commits." : ""),
            buttons: ["Remove", "Cancel"],
            checkbox: offersBranch ? "Delete local branch" : nil,
            checkboxHelp: offersBranch ? shown.branch : nil,
            defaultDeletes: true))
        // As in Remove: what the answer finds is decided on the row as it is once the alert is gone.
        guard answer.confirmed, workspace.canChangeWorkspace, let task = workspace.state.archived(id: id)?.task,
              let project = workspace.state.project(id: task.projectId),
              let token = work.begin(.removing(windowLetGo: false), onTask: id) else { return nil }
        let job = Task {
            defer { running[id] = nil; work.end(token) }
            do {
                let result = try await workflow.forgetArchived(task: task, project: project, deleteBranch: answer.checked)
                // The row goes whatever became of its branch: it has no worktree to retry, so a branch
                // git refused is kept and said so, where Remove's row waits on a Keep or Delete.
                switch result.branchRefusal {
                case .notMerged:
                    let delete = await prompter.ask(TaskRemover.deleteUnmergedBranchQuestion(for: task))
                    if delete.confirmed { try await workflow.deleteUnmergedBranch(of: task, in: project) }
                case .other(let reason):
                    var issue = OperationIssue.branchKept(task.branch, of: id, because: .other(reason: reason))
                    // Nothing to keep or delete later: the row is going. No subject either: a banner's
                    // subject names a sidebar row, and an archived one is not a row there, so a subject
                    // would make `Notices` drop the banner as stale.
                    issue.actions = []
                    issue.subject = nil
                    notices.report(issue)
                case nil:
                    break
                }
                workspace.mutate { $0.removeArchived(id: id) }
                workspace.flush()
                if workspace.persistenceError == nil {
                    notices.showToast("\(task.kindName) removed." + (result.keptBranch.map { " " + $0.note(branch: task.branch) } ?? ""))
                }
            } catch {
                // No subject, for the reason above.
                notices.report(OperationIssue(title: "Couldn’t remove the \(task.kindName.lowercased()).", error: error))
            }
        }
        running[id] = job
        return job
    }
}
