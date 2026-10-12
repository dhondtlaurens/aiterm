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
    /// Nil when nothing started: the workspace locked, the task gone or already busy.
    @discardableResult
    func archive(task: TaskItem) async -> Task<Void, Never>? {
        let state = workspace.state
        guard workspace.canChangeWorkspace, let shown = state.task(id: task.id), let project = state.project(id: shown.projectId),
              let token = work.begin(.archiving(windowLetGo: false), onTask: task.id) else { return nil }
        remover.clearOutcome(of: task.id)
        let id = task.id, kind = shown.kindName
        let job = Task {
            defer { running[id] = nil; work.end(token) }
            do { try await archive(shown, in: project, holding: token) }
            catch Stop.kept {}
            catch Stop.keptLate { remover.recordStop(of: id, note: "Not archived") }
            catch Stop.detached {
                await prompter.ask(AlertPrompt(
                    message: "“\(shown.title)” can’t be archived",
                    detail: "Its worktree isn’t on a branch, so its commits would be lost. Check out a branch, or remove the \(kind.lowercased())."))
            }
            catch TeardownStop.noDaemon {
                remover.recordStop(of: id, note: "Not archived: iTerm2 isn’t connected")
                notices.report(OperationIssue(title: "Couldn’t archive the \(kind.lowercased()).",
                                              error: ActionUnavailable("iTerm2 isn’t connected, so its window couldn’t close and nothing was deleted."),
                                              subject: id))
            }
            catch TeardownStop.windowStayedOpen(let why) {
                remover.recordStop(of: id, note: "Not archived: its window did not close")
                notices.report(OperationIssue(title: "Couldn’t archive the \(kind.lowercased()).", error: why, subject: id))
            }
            catch {
                remover.recordStop(of: id, note: "Not archived")
                notices.report(OperationIssue(title: "Couldn’t archive the \(kind.lowercased()).", error: error, subject: id))
            }
        }
        running[id] = job
        return job
    }

    private func archive(_ task: TaskItem, in project: Project, holding token: WorkInFlight.Token) async throws {
        // The branch it is on now: a task's worktree can have moved since it was created.
        let head = try await workflow.head(of: task, in: project)
        if head == .detached { throw Stop.detached }
        var force = false
        if try await workflow.hasUnsavedWork(task: task, project: project) {
            guard await teardown.confirmDeletingUnsavedWork(of: task, verb: .archive),
                  workspace.state.task(id: task.id) != nil else { throw Stop.kept }
            force = true
        }
        try await teardown.closeWindow(of: task, holding: token, requiringDaemon: true, operation: { .archiving(windowLetGo: $0) })
        let branch = if case .branch(let name) = head { name } else { task.branch }
        // On disk before the worktree goes (see the type's comment).
        workspace.mutate { $0.moveToArchive(taskId: task.id, branch: branch, at: now()) }
        guard workspace.flush() else {
            // Not on disk, so the worktree stays: deleted now, a crash before a save holds would bring
            // back a task whose checkout is gone, which the cleanup forgets. The row is a task again,
            // owed its window; the store is failing, so it is not flushed again.
            workspace.mutate { $0.moveFromArchive(id: task.id) }
            throw ActionUnavailable("Its archived row couldn’t be saved, so nothing was deleted.")
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
        if workspace.persistenceError == nil { notices.showToast("\(task.kindName) archived.", symbol: "archivebox") }
    }
}
