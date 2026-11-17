import Foundation
import AiTermCore

/// Restores archived tasks and reviews: the worktree recreated and the row put back. Choosing it, which opens its
/// window with its conversations resumed, is `AppController.restoreFromArchive`'s. Archiving and removing an archived
/// row are `TaskTeardown`'s.
@MainActor
final class TaskArchiver {
    private let workspace: WorkspaceStore
    private let work: WorkInFlight
    private let workflow: TaskWorkflow
    private let notices: Notices
    private let prompter: Prompter
    private let checkouts: CheckoutMonitor

    init(workspace: WorkspaceStore, work: WorkInFlight, workflow: TaskWorkflow, notices: Notices, prompter: Prompter,
         checkouts: CheckoutMonitor) {
        self.workspace = workspace; self.work = work; self.workflow = workflow; self.notices = notices
        self.prompter = prompter; self.checkouts = checkouts
    }

    // -- restore ------------------------------------------------------------------------
    /// Archived row `id`'s worktree back at its own path, then the row back in the sidebar — saved —
    /// and its project opened; the row's work ends with the task. A refusal before the worktree is
    /// back says why and leaves the row archived. Returns once the row is back or the restore
    /// stopped, or at once when nothing started.
    func restore(_ id: UUID) async {
        let state = workspace.state
        guard workspace.canChangeWorkspace, let entry = state.archived(id: id), let project = state.project(id: entry.task.projectId),
              let token = work.begin(.restoring, onTask: id) else { return }
        defer { work.end(token) }
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
        if workspace.persistenceError == nil { notices.showToast("\(entry.task.kindName) restored.", symbol: "tray.and.arrow.up") }
    }
}
