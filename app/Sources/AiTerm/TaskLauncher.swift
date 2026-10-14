import Foundation
import AiTermCore

/// Tasks and reviews started, and their windows: a task or review created from its sheet, and a
/// review opened in the task that already has its branch.
@MainActor
final class TaskLauncher {
    private let workspace: WorkspaceStore
    private let work: WorkInFlight
    private let notices: Notices
    private let checkouts: CheckoutMonitor
    private let focus: RowFocus
    private let tiling: SidebarTiling
    private let workflow: TaskWorkflow
    private let git: any GitRunning
    private let daemon: @MainActor () -> (any DaemonCommands)?

    init(workspace: WorkspaceStore, work: WorkInFlight, notices: Notices, checkouts: CheckoutMonitor, focus: RowFocus,
         tiling: SidebarTiling, workflow: TaskWorkflow, git: any GitRunning, daemon: @escaping @MainActor () -> (any DaemonCommands)?) {
        self.workspace = workspace
        self.work = work
        self.notices = notices
        self.checkouts = checkouts
        self.focus = focus
        self.tiling = tiling
        self.workflow = workflow
        self.git = git
        self.daemon = daemon
    }

    private var canChangeWorkspace: Bool { workspace.canChangeWorkspace }
    private var state: AppState { workspace.state }

    func createTask(draft: TaskDraft, project: Project) async throws {
        let reserved = state.reservedWorktreeSlugs(projectId: project.id)
        try await create(draft, kind: .task, in: project) { [workflow] in try await workflow.create(draft: draft, project: project, reserved: reserved) }
    }

    /// A branch already checked out in a task's worktree — or an earlier review's — is reviewed
    /// there; any other gets a worktree of its own, on the branch (see `Repository.addReviewWorktree`). Which
    /// is asked of git now, not of the saved rows: a task's worktree can have moved to another branch.
    func createReview(draft: ReviewDraft, project: Project) async throws {
        if let owner = try await checkoutOwner(of: draft.branch, in: project) {
            return try await openReview(draft, in: owner, project: project)
        }
        let reserved = state.reservedWorktreeSlugs(projectId: project.id)
        try await create(draft, kind: .review, in: project) { [workflow] in try await workflow.createReview(draft: draft, project: project, reserved: reserved) }
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

    /// The review New Review created once `agent`'s fix had landed: the toast says so, and names
    /// the backup that keeps the branch's old tip.
    func announceFix(_ landing: FixLanding, by agent: FixerAgent) {
        notices.showToast("Review created after \(agent.shortName)’s fix. Your old commits are kept as \(landing.backup).")
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
        // The row is in the workspace before its window: until this create has opened it — or given
        // up — the row is this work's, and nothing restores it underneath (`WindowReconciler`).
        let opening = work.begin(.opening, onTask: task.id)
        defer { if let opening { work.end(opening) } }
        workspace.mutate { state in
            state.tasks.append(task)
            state.rememberChoice(draft, projectId: project.id)
        }
        checkouts.refresh()
        focus.browse(.task(task.id))
        // A row that could not be saved gets no window: a relaunch would not know the window was its.
        guard workspace.flush() else { return }
        // Said once, about the new row, whatever then happens to the window: the files are missing
        // from the worktree either way. The banner holds one report, so a window report that
        // replaces it carries the sentence on (`say`).
        let copyNote = Self.report(result.worktreeInclude, of: task, to: notices)
        func say(_ issue: OperationIssue) {
            var issue = issue
            if let copyNote { issue.reason = [issue.reason, copyNote].compactMap { $0 }.joined(separator: " ") }
            notices.report(issue)
        }
        if let warning = result.launchWarning {
            say(OperationIssue(title: "\(noun) created, but the agent couldn’t start. Start it manually in its window.",
                               reason: warning))
            return
        }
        guard let daemon = daemon() else {
            say(OperationIssue(title: "\(noun) created. Its window opens once AiTerm reconnects; start the agent there manually."))
            return
        }
        do { try await openWindow(for: task, command: result.command, with: daemon) }
        catch {
            say(OperationIssue(title: "\(noun) created. Couldn’t confirm its window opened; it comes back once AiTerm reconnects.",
                               error: error))
        }
    }

    /// Says, about `task`, what its new worktree's `.worktreeinclude` copy left out, if anything did:
    /// a create and a restore both copy. The sentence said, for a later report to carry on.
    @discardableResult
    static func report(_ outcome: WorktreeInclude.Outcome, of task: TaskItem, to notices: Notices) -> String? {
        guard let note = outcome.bannerMessage else { return nil }
        notices.report(OperationIssue(title: note, subject: task.id))
        return note
    }

    /// A task's window, in its worktree, adopted by the row: its id, or nil when the row went while the
    /// window opened — it cannot adopt it, so the window is closed rather than left behind with nothing
    /// to show it. `command` is what the window's first tab runs: the agent at creation, a resumed
    /// conversation on a restore, or nothing — the first prompt is never replayed.
    /// `WindowReconciler.restore` opens a restored task's window through it too.
    @discardableResult
    func openWindow(for task: TaskItem, command: String?, with daemon: any DaemonCommands) async throws -> String? {
        let opening = work.begin(.openingTaskWindow, onProject: task.projectId)
        defer { if let opening { work.end(opening) } }
        let wid = try await daemon.createTaskWindow(taskId: task.id.uuidString, cwd: task.worktreePath, title: task.branch,
                                                    agentCommand: command, frame: tiling.taskFrame())
        guard let i = state.tasks.firstIndex(where: { $0.id == task.id }) else {
            try? await daemon.closeWindowIfOpen(wid)
            return nil
        }
        workspace.mutate { $0.tasks[i].windowId = wid }
        return wid
    }
}
