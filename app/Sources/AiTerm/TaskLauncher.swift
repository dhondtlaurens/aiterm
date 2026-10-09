import Foundation
import AiTermCore

/// Tasks and reviews started, and their windows: a task or review created from its sheet, a review
/// opened in the task that already has its branch, and Reopen Window for a task that lost its own.
@MainActor
final class TaskLauncher {
    private let workspace: WorkspaceStore
    private let work: WorkInFlight
    private let notices: Notices
    private let checkouts: CheckoutMonitor
    private let focus: RowFocus
    private let tiling: SidebarTiling
    /// Clears the "Kept; choose Reopen Window" a removal left, once Reopen Window has done it.
    private let remover: TaskRemover
    private let workflow: TaskWorkflow
    private let git: any GitRunning
    private let daemon: @MainActor () -> (any DaemonCommands)?

    init(workspace: WorkspaceStore, work: WorkInFlight, notices: Notices, checkouts: CheckoutMonitor, focus: RowFocus,
         tiling: SidebarTiling, remover: TaskRemover, workflow: TaskWorkflow, git: any GitRunning,
         daemon: @escaping @MainActor () -> (any DaemonCommands)?) {
        self.workspace = workspace
        self.work = work
        self.notices = notices
        self.checkouts = checkouts
        self.focus = focus
        self.tiling = tiling
        self.remover = remover
        self.workflow = workflow
        self.git = git
        self.daemon = daemon
    }

    private var canChangeWorkspace: Bool { workspace.canChangeWorkspace }
    private var state: AppState { workspace.state }

    func createTask(draft: TaskDraft, project: Project) async throws {
        try await create(draft, kind: .task, in: project) { [workflow] in try await workflow.create(draft: draft, project: project) }
    }

    /// A branch already checked out in a task's worktree — or an earlier review's — is reviewed
    /// there; any other gets a worktree of its own, on the branch (see `Repository.addReviewWorktree`). Which
    /// is asked of git now, not of the saved rows: a task's worktree can have moved to another branch.
    func createReview(draft: ReviewDraft, project: Project) async throws {
        if let owner = try await checkoutOwner(of: draft.branch, in: project) {
            return try await openReview(draft, in: owner, project: project)
        }
        try await create(draft, kind: .review, in: project) { [workflow] in try await workflow.createReview(draft: draft, project: project) }
    }

    /// The fix New Review's footer offered for a refused branch, run before its create is tried
    /// again: the project's own folder switched off the branch, or the diverged branch rebased onto
    /// origin's. Either moves a branch the sidebar shows, so the checkouts are read again.
    func recover(_ recovery: CreationFailure.Recovery, in project: Project) async throws {
        switch recovery {
        case .switchProjectFolder(let branch, let target): try await workflow.switchProjectFolder(of: project, off: branch, to: target)
        case .rebase(let branch): _ = try await workflow.rebaseOntoOrigin(branch, in: project)
        }
        checkouts.refresh()
    }

    /// The review as a tab in `owner`'s window, running the reviewer in the task's worktree — or
    /// the window itself, reopened with the reviewer, when the task has none. Nothing is written
    /// to disk and no row is added, so closing the tab ends the review and there is nothing whose
    /// removal could reach the task's worktree or branch. For the same reason every failure is the
    /// sheet's: the draft is still there to retry.
    private func openReview(_ draft: ReviewDraft, in owner: TaskItem, project: Project) async throws {
        guard canChangeWorkspace else { throw ActionUnavailable("Save or recover the workspace before opening a review.") }
        guard FileManager.default.fileExists(atPath: owner.worktreePath) else {
            throw ActionUnavailable("“\(owner.title)” has this branch, but its worktree is missing at \(owner.worktreePath). Restore it or remove the task.")
        }
        guard let daemon = daemon() else { throw ActionUnavailable(OperationIssue.disconnected("again").title) }
        guard let reviewing = work.begin(.reviewing, onTask: owner.id) else { throw ActionUnavailable("“\(owner.title)” is busy. Try again in a moment.") }
        defer { work.end(reviewing) }
        let opening = work.begin(.openingTaskWindow, onProject: owner.projectId)
        defer { if let opening { work.end(opening) } }
        let command = try await workflow.reviewCommand(draft: draft, in: owner)
        guard let current = state.task(id: owner.id) else { throw ActionUnavailable("“\(owner.title)” was removed.") }
        // Checked again last thing: a checkout in the task's own tab can have moved it meanwhile.
        // Its worktree is never switched back — the review would take over someone's checkout.
        guard try await checkoutOwner(of: draft.branch, in: project)?.id == owner.id else {
            throw ActionUnavailable("“\(owner.title)” no longer has \(draft.branch) checked out. Try again to review it where it is now.")
        }
        var opened = false
        if let wid = current.windowId {
            do {
                _ = try await daemon.createTab(windowId: wid, cwd: current.worktreePath, agentCommand: command)
                opened = true
                try? await daemon.activate(windowId: wid)
            }
            // Closed since the last poll: reopened below, as a task with no window is.
            catch let error as DaemonError where error.isNotFound {}
        }
        if !opened { try await openWindow(for: current, command: command, with: daemon) }
        workspace.mutate { state in
            if let mr = draft.mr, let i = state.tasks.firstIndex(where: { $0.id == owner.id }) {
                state.tasks[i].mr = MergeRequestRef(iid: mr.iid, title: mr.title, url: mr.url)
            }
            state.rememberChoice(draft, projectId: owner.projectId)
        }
        focus.browse(.task(owner.id))
    }

    /// The row whose worktree has `branch` checked out, by git's own worktree listing.
    private func checkoutOwner(of branch: String, in project: Project) async throws -> TaskItem? {
        guard !branch.isEmpty else { return nil }
        let git = self.git, repo = project.path
        let worktrees = try await BackgroundWork.run { try Repository(repo, git: git).worktrees() }
        return state.task(checkingOut: branch, in: project.id, worktrees: worktrees)
    }

    /// Commits the new row's identity before any terminal effect. A created task is never a failed
    /// form submission: the sheet closes, and any recovery is offered on the existing row.
    ///
    /// The new row is selected and its window opens beside the sidebar, but iTerm2 is not brought
    /// forward: the agent is already working on the prompt, so the keyboard stays in the sidebar,
    /// as after a peek, and Return commits. A new terminal, which has nothing running, does come
    /// forward (see `TerminalActions.newTerminal(project:name:)`).
    private func create(_ draft: some AgentDraft, kind: TaskKind, in project: Project,
                        checkout: () async throws -> TaskWorkflow.Created) async throws {
        let noun = kind == .review ? "Review" : "Task"
        guard canChangeWorkspace else {
            throw ActionUnavailable("Save or recover the workspace before creating a \(noun.lowercased()).")
        }
        guard let creating = work.begin(.creatingTask, onProject: project.id) else {
            throw ActionUnavailable("A task or review is already being created in \(project.name). Try again once it is.")
        }
        defer { work.end(creating) }
        let result = try await checkout()
        let task = result.task
        workspace.mutate { state in
            state.tasks.append(task)
            state.rememberChoice(draft, projectId: project.id)
        }
        checkouts.refresh()
        focus.browse(.task(task.id))
        // A row that could not be saved gets no window: a relaunch would not know the window was its.
        guard workspace.flush() else { return }
        if let warning = result.launchWarning {
            notices.report(OperationIssue(title: "\(noun) created, but the agent couldn’t start. Choose Reopen Window, then start the agent manually.",
                                          reason: warning))
            return
        }
        guard let daemon = daemon() else {
            notices.report("\(noun) created. Once AiTerm reconnects, choose Reopen Window and start the agent manually.")
            return
        }
        do { try await openWindow(for: task, command: result.command, with: daemon) }
        catch {
            notices.report(OperationIssue(title: "\(noun) created. Couldn’t confirm its window opened. Wait for reconnection or choose Reopen Window.",
                                          error: error))
        }
    }

    /// A task's window, in its worktree, adopted by the row. `command` launches its agent; a reopened
    /// window gets none — the first prompt is never replayed. A row that went while the window opened
    /// cannot adopt it, so the window is closed rather than left behind with nothing to show it.
    private func openWindow(for task: TaskItem, command: String?, with daemon: any DaemonCommands) async throws {
        let opening = work.begin(.openingTaskWindow, onProject: task.projectId)
        defer { if let opening { work.end(opening) } }
        let wid = try await daemon.createTaskWindow(taskId: task.id.uuidString, cwd: task.worktreePath, title: task.branch,
                                                    agentCommand: command, frame: tiling.taskFrame())
        guard let i = state.tasks.firstIndex(where: { $0.id == task.id }) else {
            try? await daemon.closeWindowIfOpen(wid)
            return
        }
        workspace.mutate { $0.tasks[i].windowId = wid }
    }

    /// A task that still has a window has nothing to reopen — the menu item is hidden
    /// in that case, and a stale click is ignored rather than leaking a second window.
    @discardableResult
    func reopen(task: TaskItem) -> Task<Void, Never>? {
        guard canChangeWorkspace else { return nil }
        guard let current = state.task(id: task.id), current.windowId == nil else { return nil }
        guard let daemon = daemon() else { notices.report(.disconnected("Reopen Window again")); return nil }
        guard let reopening = work.begin(.reopening, onTask: task.id) else { return nil }
        guard FileManager.default.fileExists(atPath: current.worktreePath) else {
            work.end(reopening)
            notices.report("Worktree missing at \(current.worktreePath). Restore it or use Remove \(current.kindName).")
            return nil
        }
        return Task {
            defer { work.end(reopening) }
            guard canChangeWorkspace else { return }
            do {
                try await openWindow(for: current, command: nil, with: daemon)
                // "Kept; choose Reopen Window" was asking for exactly this.
                remover.clearStoppedNote(of: task.id)
                notices.dropIssues(about: task.id)
            } catch { notices.report(OperationIssue(title: "Couldn’t reopen the window.", error: error)) }
        }
    }
}
