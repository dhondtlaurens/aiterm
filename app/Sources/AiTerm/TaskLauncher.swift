import Foundation
import AiTermCore

/// A project already busy creating a task or review. A sheet says it as before; a signal's pick-up waits for its next
/// turn without counting a failure.
struct CreationBusy: LocalizedError, CustomStringConvertible {
    let project: String
    var errorDescription: String? { description }
    var description: String { "A task or review is already being created in \(project). Try again once it is." }
}

/// Tasks and reviews started, restored and opened: a task or review created from its sheet, a review
/// opened in the task that already has its branch, an archived row restored, a worker's checkout made,
/// a driven task taken over by the person, and a task's window opened with its conversations resumed.
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
    /// Where a driven task's branch guard keeps its files, and the executable its hooks run.
    private let home: URL
    private let workerGuardExecutable: URL
    /// The code hosts' connections, which find a request task's request: the Operator's, once it exists.
    var connections: @MainActor () async -> SignalConnections = { SignalConnections() }

    init(workspace: WorkspaceStore, work: WorkInFlight, notices: Notices, checkouts: CheckoutMonitor, focus: RowFocus,
         tiling: SidebarTiling, workflow: TaskWorkflow, git: any GitRunning, home: URL, workerGuardExecutable: URL,
         daemon: @escaping @MainActor () -> (any DaemonCommands)?) {
        self.workspace = workspace
        self.work = work
        self.notices = notices
        self.checkouts = checkouts
        self.focus = focus
        self.tiling = tiling
        self.workflow = workflow
        self.git = git
        self.home = home
        self.workerGuardExecutable = workerGuardExecutable
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
        try await create(draft, kind: .review, in: project) { [workflow] in
            try await workflow.createReview(draft: draft, project: project, reserved: reserved)
        }
    }

    /// The recovery a creation footer offered for a refused branch, run before its create is tried
    /// again: switch the project's folder, rebase a diverged branch, or explicitly initialize an
    /// unborn base while holding the project's creation slot. Each changes what the sidebar's
    /// checkout monitor knows, so the checkouts are read again.
    func recover(_ recovery: CreationFailure.Recovery, in project: Project) async throws {
        switch recovery {
        case .switchProjectFolder(let branch, let target): try await workflow.switchProjectFolder(of: project, off: branch, to: target)
        case .rebase(let branch): _ = try await workflow.rebaseOntoOrigin(branch, in: project)
        case .initializeRepository(let branch):
            guard canChangeWorkspace else { throw ActionUnavailable("Save or recover the workspace before initializing a repository.") }
            guard let creating = work.begin(.creatingTask, onProject: project.id) else { throw CreationBusy(project: project.name) }
            defer { work.end(creating) }
            try await workflow.initializeRepository(project, on: branch)
        }
        checkouts.refresh()
    }

    /// Start an interactive reviewer in the owner's checkout: a tab in its window, or the first
    /// tab of a reopened window. No row or checkout is added. Delivery errors go back to the sheet.
    private func openReview(_ draft: ReviewDraft, in owner: TaskItem, project: Project) async throws {
        guard canChangeWorkspace else { throw ActionUnavailable("Save or recover the workspace before opening a review.") }
        guard await FolderCheck.exists(owner.worktreePath) else {
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
                let tab = try await daemon.createTab(windowId: wid, cwd: current.worktreePath, agentCommand: command, tabKey: nil, background: false)
                if let failure = tab.commandError {
                    throw ActionUnavailable("The review command could not start: " + failure)
                }
                opened = true
                try? await daemon.activate(windowId: wid)
            }
            // Closed since the last poll: reopened below, as a task with no window is.
            catch let error as DaemonError where error.isNotFound {}
        }
        if !opened {
            guard let window = try await openWindow(for: current, command: command, with: daemon) else {
                throw ActionUnavailable("The task was removed while opening its review.")
            }
            if let failure = window.commandError {
                throw ActionUnavailable("The review command could not start: " + failure)
            }
        }
        workspace.mutate { state in
            if let i = state.tasks.firstIndex(where: { $0.id == owner.id }) {
                if let mr = draft.mr { state.tasks[i].mr = MergeRequestRef(iid: mr.iid, title: mr.title, url: mr.url) }
                // The picked ticket goes on a row that has none; one with its own keeps it, the task's
                // own ticket, and the review tab's prompt still carries the picked one.
                if state.tasks[i].jira == nil, let ticket = draft.ticket { state.tasks[i].jira = JiraRef(ticket) }
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
        let creating = try beginCreating(noun, in: project)
        defer { work.end(creating) }
        let result = try await checkout()
        let task = result.task
        // The row is in the workspace before its window: until this create has opened it — or given
        // up — the row is this work's, and choosing it opens no second window (`RowWindows`).
        let opening = work.begin(.opening, onTask: task.id)
        defer { if let opening { work.end(opening) } }
        workspace.mutate { state in
            state.tasks.append(task)
            state.rememberChoice(draft, projectId: project.id)
        }
        checkouts.refresh()
        focus.browse(.task(task.id))
        // A row that could not be saved gets no window: a relaunch would not know the window was its.
        guard workspace.flush(), let say = reportMade(result, noun: noun) else { return }
        guard let daemon = daemon() else {
            say(OperationIssue(title: "\(noun) created. Choose it to open its window once AiTerm reconnects, then start the agent there."))
            return
        }
        do {
            // The window is there, but its agent command was never typed: a plain shell, said on the row.
            if let failure = try await openWindow(for: task, command: result.command, with: daemon)?.commandError {
                say(OperationIssue(title: "Opened the window, but its agent didn’t start.", reason: failure, subject: task.id))
            }
        } catch {
            say(OperationIssue(title: "\(noun) created. Couldn’t confirm its window opened; if it isn’t there once AiTerm reconnects, choose the task to open it.",
                               error: error))
        }
    }

    /// The project's one creation slot, taken: refused while the workspace cannot change, and `CreationBusy` while another
    /// task or review is being created in the project.
    private func beginCreating(_ noun: String, in project: Project) throws -> WorkInFlight.Token {
        guard canChangeWorkspace else {
            throw ActionUnavailable("Save or recover the workspace before creating a \(noun.lowercased()).")
        }
        guard let creating = work.begin(.creatingTask, onProject: project.id) else { throw CreationBusy(project: project.name) }
        return creating
    }

    /// Says once, about the new row, what its worktree's `.worktreeinclude` copy left out, whatever then happens to its
    /// window: the files are missing from the worktree either way; and, when its agent command could not be built, that
    /// the agent must be started by hand. Returns how a later report carries the copy's sentence on, as the banner holds
    /// one report and a window report replaces it; nil once the launch warning was said. `subject` is the row the
    /// warning is said on: none for a sheet's create, whose row is the selection.
    private func reportMade(_ result: TaskWorkflow.Created, noun: String, subject: UUID? = nil) -> ((OperationIssue) -> Void)? {
        let copyNote = Self.report(result.worktreeInclude, of: result.task, to: notices)
        let notices = notices
        let say = { (issue: OperationIssue) in
            var issue = issue
            if let copyNote { issue.reason = [issue.reason, copyNote].compactMap { $0 }.joined(separator: " ") }
            notices.report(issue)
        }
        guard let warning = result.launchWarning else { return say }
        say(OperationIssue(title: "\(noun) created, but the agent couldn’t start. Start it manually in its window.",
                           reason: warning, subject: subject))
        return nil
    }

    // -- an unattended create -----------------------------------------------------------
    /// A task a project signal makes on its own: what to create, in which project, and what to save with the row.
    struct UnattendedCreate {
        enum Kind {
            /// A ticket's task, on a new branch.
            case task(TaskDraft)
            /// A scheduled run's task, on a new run branch.
            case run(TaskDraft)
            /// A merge request someone else asked the account to review.
            case review(ReviewDraft)
            /// A merge request of the account's own: its source branch checked out as a `.task` (`TaskWorkflow.createOnRequest`).
            case ownRequest(ReviewDraft)

            /// The prompt its draft composes: its text with the descriptions its switches add. A re-match composes one too,
            /// for the task's existing conversation.
            var prompt: String? {
                switch self {
                case .task(let draft), .run(let draft): TaskWorkflow.prompt(of: draft)
                case .review(let draft), .ownRequest(let draft): TaskWorkflow.prompt(of: draft)
                }
            }
        }
        let project: Project
        let kind: Kind
        /// Run inside the workspace change that appends the row, given the row's id: the signal's origin, its seen record.
        let saving: @MainActor (inout AppState, UUID) -> Void

        /// The first prompt the create composes for the row's agent, the one `openUnattended` is to be given: the draft's
        /// text with the descriptions its switches add, composed here and never again.
        var prompt: String? { kind.prompt }
    }

    /// `request`'s row made without the person: the checkout (git, on the repository's lane), then the row appended in
    /// one workspace change with what `request.saving` writes, and saved. Unlike a sheet's create it selects nothing,
    /// opens no window and remembers no agent choice (a signal's agent is not the person's last one); what its
    /// `.worktreeinclude` copy left out, and a launch warning, are said on the row. The window is `openUnattended`'s.
    ///
    /// Throws `CreationBusy` while the project creates another task or review; the checkout's own failure, with git's
    /// reason; for a review or an own request whose branch another row has checked out, that row's title (a sheet's
    /// review would open in that row's window: this never opens a tab or brings anything forward); and when the row
    /// could not be saved, which leaves it in the workspace, unsaved, with what `saving` wrote.
    func createUnattended(_ request: UnattendedCreate) async throws -> UUID {
        let project = request.project
        let branch: String? = switch request.kind {
        case .task, .run: nil
        case .review(let draft): draft.branch
        case .ownRequest(let draft): draft.mr?.sourceBranch ?? draft.branch
        }
        if let branch, let owner = try await checkoutOwner(of: branch, in: project) {
            throw ActionUnavailable("“\(owner.title)” has \(branch) checked out.")
        }
        let reserved = state.reservedWorktreeSlugs(projectId: project.id)
        let workflow = workflow
        switch request.kind {
        case .task(let draft), .run(let draft):
            return try await createUnattended(noun: "Task", in: project, saving: request.saving) {
                try await workflow.create(draft: draft, project: project, reserved: reserved)
            }
        case .review(let draft):
            return try await createUnattended(noun: "Review", in: project, saving: request.saving) {
                try await workflow.createReview(draft: draft, project: project, reserved: reserved)
            }
        case .ownRequest(let draft):
            guard let mr = draft.mr else { throw ActionUnavailable("The merge request to check out is missing.") }
            return try await createUnattended(noun: "Task", in: project, saving: request.saving) {
                try await workflow.createOnRequest(draft: draft, project: project, source: mr.sourceBranch, target: mr.targetBranch,
                                                   reserved: reserved)
            }
        }
    }

    /// `create`'s order without the person's part: no selection, no window, no remembered choice.
    private func createUnattended(noun: String, in project: Project, saving: (inout AppState, UUID) -> Void,
                                  checkout: () async throws -> TaskWorkflow.Created) async throws -> UUID {
        let creating = try beginCreating(noun, in: project)
        defer { work.end(creating) }
        let result = try await checkout()
        let task = result.task
        // As a sheet's create: the row is this work's until it is saved, so choosing it meanwhile opens no window.
        let opening = work.begin(.opening, onTask: task.id)
        defer { if let opening { work.end(opening) } }
        workspace.mutate { state in
            state.tasks.append(task)
            saving(&state, task.id)
        }
        checkouts.refresh()
        guard workspace.flush() else {
            throw ActionUnavailable("\(noun) created, but the workspace couldn’t be saved. Recover it before its window opens.")
        }
        _ = reportMade(result, noun: noun, subject: task.id)
        return task.id
    }

    /// Signal task `id`'s agent started on `prompt`, behind whatever the person is doing: the caller holds the person's
    /// pause and the window turn. A task with no window gets one opened behind (`createTaskWindow(background: true)`)
    /// with the ordinary agent command (`TaskWorkflow.command`), resuming the task's first conversation of its own agent
    /// when there is one, and every other conversation resumed in a background tab; a task whose window is open, which
    /// the caller found running no agent, gets the command in a background tab there. `saving` runs in the change that
    /// records the window, or right after the tab opened, and only once the command was typed: a window or tab that did
    /// not open, or whose command could not be typed, is thrown without it. A conversation that did not resume in its
    /// own tab is said on the row. `mayOpen` is the caller's last look (the person's pause), taken after the folder check,
    /// the command and every other await, with none between it and the request for the window or tab: false opens
    /// nothing and returns false, for the caller to wait and ask again.
    @discardableResult
    func openUnattended(_ id: UUID, prompt: String, saving: @escaping @MainActor (inout AppState) -> Void = { _ in },
                        mayOpen: @MainActor () -> Bool = { true }) async throws -> Bool {
        let removed = ActionUnavailable("The task was removed.")
        guard canChangeWorkspace else { throw ActionUnavailable("Save or recover the workspace before opening a task’s window.") }
        guard let task = state.task(id: id) else { throw removed }
        guard let daemon = daemon() else { throw ActionUnavailable(OperationIssue.disconnected("again").title) }
        guard let token = work.begin(.reopening, onTask: id) else { throw ActionUnavailable("“\(task.title)” is busy. Try again in a moment.") }
        defer { work.end(token) }
        guard await FolderCheck.exists(task.worktreePath) else {
            // The checkout monitor's pass, asked for now, says so on the row.
            checkouts.refresh()
            throw ActionUnavailable("“\(task.title)” has no worktree at \(task.worktreePath).")
        }
        guard let current = state.task(id: id) else { throw removed }
        let resumed = current.conversations.first { $0.agent == current.agent && TaskConversation.isResumable($0.id) }
        let command = try await workflow.command(for: current, prompt: prompt, resuming: resumed?.id)
        guard let ready = state.task(id: id) else { throw removed }
        guard mayOpen() else { return false }
        if let windowId = ready.windowId {
            do {
                let tab = try await daemon.createTab(windowId: windowId, cwd: ready.worktreePath, agentCommand: command, tabKey: nil, background: true, worker: ready.isUnderOperator)
                if let failure = tab.commandError { throw ActionUnavailable("Opened a tab, but its agent didn’t start: \(failure)") }
                guard state.task(id: id) != nil else { throw removed }
                workspace.mutate(saving)
                return true
            }
            // Closed since the last poll: opened below, as a task with no window is.
            catch let error as DaemonError where error.isNotFound {}
            guard mayOpen() else { return false }
        }
        guard let opened = try await openWindow(for: ready, command: command, with: daemon, background: true,
                                                saving: { state, opened in if opened.commandError == nil { saving(&state) } }) else {
            throw removed
        }
        if let failure = opened.commandError { throw ActionUnavailable("Opened the window, but its agent didn’t start: \(failure)") }
        var others = ready
        if let resumed { others.conversations.removeAll { $0 == resumed } }
        for resume in others.resumeCommands {
            do {
                let tab = try await daemon.createTab(windowId: opened.id, cwd: ready.worktreePath, agentCommand: resume, tabKey: nil, background: true, worker: ready.isUnderOperator)
                if let failure = tab.commandError {
                    notices.report(OperationIssue(title: "Opened the window, but not every conversation.", reason: failure, subject: id))
                    break
                }
            } catch {
                notices.report(OperationIssue(title: "Opened the window, but not every conversation.", error: error, subject: id))
                break
            }
        }
        return true
    }

    /// Says, about `task`, what its new worktree's `.worktreeinclude` copy left out, if anything did:
    /// a create and a restore both copy. The sentence said, for a later report to carry on.
    @discardableResult
    static func report(_ outcome: WorktreeInclude.Outcome, of task: TaskItem, to notices: Notices) -> String? {
        guard let note = outcome.bannerMessage else { return nil }
        notices.report(OperationIssue(title: note, subject: task.id))
        return note
    }

    // -- restore ------------------------------------------------------------------------
    /// Archived row `id`'s worktree back at its own path, then the row back in the sidebar, saved, with
    /// what its `.worktreeinclude` copy left out said on it. The row back, or nil when nothing started
    /// (the workspace can't change, the row isn't archived, its project is gone, the row is busy) or
    /// when the workspace locked while git ran: the row stays archived then, and the next restore adopts
    /// its worktree. Git's refusal is thrown, the row still archived. Chooses nothing, opens no project
    /// and says nothing more: that is the person's restore's (`AppController.restoreFromArchive`).
    func restore(_ id: UUID) async throws -> TaskItem? {
        guard canChangeWorkspace, let entry = state.archived(id: id), let project = state.project(id: entry.task.projectId),
              let token = work.begin(.restoring, onTask: id) else { return nil }
        defer { work.end(token) }
        let made = try await workflow.restore(entry.task, project: project)
        // Its project cannot have gone, as removing it waits for this, but the workspace can have locked.
        guard canChangeWorkspace, state.archived(id: id) != nil, state.project(id: project.id) != nil else { return nil }
        workspace.mutate { $0.moveFromArchive(id: id) }
        // The checkout monitor forgot the row when it was archived, as it does a new row's before
        // its first pass.
        checkouts.refresh()
        workspace.flush()
        Self.report(made.worktreeInclude, of: made.task, to: notices)
        return state.task(id: id)
    }

    // -- a worker's checkout ------------------------------------------------------------
    /// `task`'s worktree for a worker: for a task with a request, the request's source branch (a fork's is
    /// not in this repository and is refused) with its target as base; otherwise a new branch from git's
    /// default branch, or what an earlier attempt left (`TaskWorkflow.checkOutWorker`). `stillAllowed` is
    /// asked after every await. The worktree is the task's, whoever asked: one the person took over meanwhile
    /// (`AppState.takeOver`) has it made all the same, as Take Over leaves this checkout to finish, and once
    /// git has made it, it is saved on the task while it is still on the same project and branch without a
    /// checkout, even when `stillAllowed` then says no. Only then is that refusal thrown. Callers save nothing.
    /// A failure after the person took the task over meanwhile is said on the task here, as its caller has lost it.
    func checkOutWorker(_ task: TaskItem, stillAllowed: @escaping @MainActor () -> Bool) async throws
        -> (task: TaskItem, includes: WorktreeInclude.Outcome) {
        func check() throws {
            guard stillAllowed() || takenOverMeanwhile() else { throw ActionUnavailable("The task changed while its worktree was made.") }
        }
        func takenOverMeanwhile() -> Bool {
            guard let current = state.task(id: task.id) else { return false }
            return current.takenOver && current.projectId == task.projectId && current.branch == task.branch
        }
        guard let project = state.project(id: task.projectId) else { throw ActionUnavailable("This task's project is busy.") }
        guard let token = work.begin(.opening, onTask: task.id) else { throw ActionUnavailable("This task's project is busy.") }
        let projectToken = work.begin(.openingTaskWindow, onProject: project.id)
        defer {
            work.end(token)
            if let projectToken { work.end(projectToken) }
        }
        // Made and saved: everything that can fail before the worktree is the task's.
        func make() async throws -> (task: TaskItem, includes: WorktreeInclude.Outcome) {
            let made: TaskCreator.Made
            if task.mr != nil {
                let links = await connections()
                try check()
                let host = try CodeHosts.repository(for: ProviderDetector.detect(remoteUrl: project.remoteUrl),
                                                    gitLab: links.gitLab, gitHub: links.gitHub, session: links.session)
                guard let request = try await host.existingRequest(from: task.branch), request.forkHead == nil else {
                    throw ActionUnavailable("The request's source branch is unavailable in this repository. Open it yourself to choose its checkout.")
                }
                try check()
                made = try await workflow.checkOutRequest(task, project: project, source: request.sourceBranch, target: request.targetBranch,
                                                          reserved: state.reservedWorktreeSlugs(projectId: project.id))
            } else {
                let git = git, path = project.path
                let start = await BackgroundWork.run { Repository(path, git: git).defaultBranch() }
                try check()
                made = try await workflow.checkOutWorker(task, project: project, start: start,
                                                         reserved: state.reservedWorktreeSlugs(projectId: project.id)).made
            }
            guard canChangeWorkspace, let current = state.task(id: task.id), current.projectId == task.projectId,
                  current.branch == task.branch, !current.hasCheckout else {
                throw ActionUnavailable("The task changed while its worktree was made.")
            }
            workspace.mutate { state in
                guard let index = state.tasks.firstIndex(where: { $0.id == task.id }) else { return }
                state.tasks[index].worktreePath = made.task.worktreePath
                state.tasks[index].baseBranch = made.task.baseBranch
            }
            guard workspace.flush(), let saved = state.task(id: task.id) else {
                throw ActionUnavailable("The checkout could not be saved. Recover the workspace before opening its window.")
            }
            return (saved, made.worktreeInclude)
        }
        let result: (task: TaskItem, includes: WorktreeInclude.Outcome)
        do { result = try await make() } catch {
            // Its caller lost the task to the person, so no one else would say it.
            if !task.takenOver && takenOverMeanwhile() { notices.report(Self.worktreeNotMade(error, about: task.id)) }
            throw error
        }
        guard stillAllowed() else { throw ActionUnavailable("The task changed while its worktree was made.") }
        return result
    }

    /// What a taken-over task's banner says when its worktree could not be made: Take Over's own checkout, or the
    /// Operator's that it left to finish.
    private static func worktreeNotMade(_ error: Error, about id: UUID) -> OperationIssue {
        OperationIssue(title: "The task is yours, but its worktree couldn’t be made.", error: error, subject: id)
    }

    // -- Take Over ----------------------------------------------------------------------
    /// The person's Take Over of driven task `id`: the task becomes an ordinary task of its project
    /// (`AppState.takeOver`), saved, and returns once what follows has been tried once. A failed save stops
    /// there. Each guard scope a worker of the task was launched with is written again with the raised
    /// ownership, so a launch already past its last claim check cannot write one that still grants it; the
    /// scope stays, as a worker still running uses it. A task whose worker never started gets its worktree
    /// now, as an ordinary task has one, unless the Operator's checkout for it is under way: that one carries
    /// on for the person and saves its folder on the task (`checkOutWorker`). Each failure is said on the task.
    func takeOver(_ id: UUID) async {
        guard canChangeWorkspace, state.task(id: id)?.isUnderOperator == true else { return }
        var removed: SignalTask?
        workspace.mutate { removed = $0.takeOver(id) }
        guard let record = removed, workspace.flush() else { return }
        let home = home, executable = workerGuardExecutable, ownership = record.ownership + 1
        if let daemon = daemon() {
            do { try await daemon.setWorkerSessions(taskId: id.uuidString, sessionIds: [], released: true, ownership: ownership) }
            catch { notices.report(OperationIssue(title: "Couldn’t release the worker tabs.", error: error, subject: id)) }
        }
        let slots = ["main"] + record.extraTabs.map(\.key)
        do {
            try await BackgroundWork.run {
                for slot in slots {
                    guard var scope = WorkerGuardLaunch.recordedScope(task: id, home: home, slot: slot) else { continue }
                    scope.ownership = ownership
                    _ = try WorkerGuardLaunch.prepare(scope: scope, home: home, slot: slot, executable: executable)
                }
            }
        } catch {
            notices.report(OperationIssue(title: "The task is yours, but its branch guard couldn’t be refreshed.", error: error, subject: id))
        }
        guard let task = state.task(id: id), task.takenOver, !task.hasCheckout, work.operation(onTask: id) != .opening else { return }
        func stillAllowed() -> Bool {
            guard let current = state.task(id: id) else { return false }
            return current.takenOver && current.projectId == task.projectId && current.branch == task.branch
        }
        do {
            let made = try await checkOutWorker(task, stillAllowed: stillAllowed)
            checkouts.refresh()
            Self.report(made.includes, of: made.task, to: notices)
        } catch {
            notices.report(Self.worktreeNotMade(error, about: id))
        }
    }

    // -- opening a window ---------------------------------------------------------------
    /// A task's or review's window, manual or driven, opened in its worktree when it has none: the first
    /// of `openCommands(for:)` in the window's own tab, each other in a tab of its own. A worktree gone
    /// opens nothing, and the checkout monitor's pass, asked for now, says so on the row. Returns at once
    /// when the row has a window, is gone or busy, or no helper is there. A window or tab whose command
    /// could not be typed, and a tab that does not open, are said on the row; a window that does not
    /// open is thrown.
    func open(_ id: UUID) async throws {
        guard let task = state.task(id: id), task.windowId == nil, let daemon = daemon(),
              let token = work.begin(.reopening, onTask: id) else { return }
        defer { work.end(token) }
        // The checkout monitor reads a worktree gone only at its next pass: one gone before then has
        // nothing to open in, and that pass, asked for now, says so on the row.
        guard await FolderCheck.exists(task.worktreePath) else {
            checkouts.refresh()
            return
        }
        guard let current = state.task(id: id), current.windowId == nil else { return }
        let commands = try await openCommands(for: current)
        guard let ready = state.task(id: id), ready.windowId == nil else { return }
        guard let opened = try await openWindow(for: ready, command: commands.first, with: daemon) else { return }
        // The window is there, but its first command was never typed: a plain shell, said on the row.
        if let failure = opened.commandError {
            let title = !ready.isUnderOperator ? "Reopened the window, but not every conversation."
                                                : "Reopened the window, but its worker didn’t resume."
            notices.report(OperationIssue(title: title, reason: failure, subject: id))
        } else {
            notices.dropIssues(about: id)
        }
        for command in commands.dropFirst() {
            do {
                let tab = try await daemon.createTab(windowId: opened.id, cwd: ready.worktreePath, agentCommand: command, tabKey: nil, background: false)
                if let failure = tab.commandError {
                    notices.report(OperationIssue(title: "Reopened the window, but not every conversation.", reason: failure, subject: id))
                    break
                }
            } catch {
                notices.report(OperationIssue(title: "Reopened the window, but not every conversation.", error: error, subject: id))
                break
            }
        }
    }

    /// What an opened task's window runs, by who owns the task: a task of the person's resumes each
    /// remembered conversation plainly (`TaskItem.resumeCommands`); a driven task resumes its first
    /// worker's conversation under its branch guard, with no prompt, on the guard's main slot.
    private func openCommands(for task: TaskItem) async throws -> [String] {
        guard task.isUnderOperator else { return task.resumeCommands }
        guard let conversation = task.firstWorkerConversation?.id else {
            throw ActionUnavailable("Its worker has no saved conversation to reopen.")
        }
        let remote = state.project(id: task.projectId)?.remoteUrl, home = home, executable = workerGuardExecutable, git = git
        let command = try await BackgroundWork.run {
            try WorkerGuardLaunch.workerCommand(task: task, prompt: "", resuming: conversation, slot: "main", remote: remote,
                                                home: home, executable: executable, git: git)
        }
        return [command]
    }

    /// A task's window, in its worktree, adopted by the row: its id and why its command could not be
    /// typed, if it could not, or nil when the row went while the window opened — it cannot adopt it, so
    /// the window is closed rather than left behind with nothing to show it. `command` is what the
    /// window's first tab runs: the agent at creation, a resumed conversation when a chosen row opens its
    /// window again, or nothing — the first prompt is never replayed. `open(_:)` opens a chosen task's
    /// window through it too. `background` opens it behind the person's windows (a signal's task);
    /// `saving` runs in the change that records the window.
    @discardableResult
    func openWindow(for task: TaskItem, command: String?, with daemon: any DaemonCommands, background: Bool = false,
                    saving: (inout AppState, Opening) -> Void = { _, _ in }) async throws -> Opening? {
        let opening = work.begin(.openingTaskWindow, onProject: task.projectId)
        defer { if let opening { work.end(opening) } }
        let opened = try await daemon.createTaskWindow(taskId: task.id.uuidString, cwd: task.worktreePath, title: task.branch,
                                                       agentCommand: command, frame: tiling.taskFrame(), background: background, worker: task.isUnderOperator)
        guard let i = state.tasks.firstIndex(where: { $0.id == task.id }) else {
            try? await daemon.closeWindowIfOpen(opened.id)
            return nil
        }
        workspace.mutate { state in
            state.tasks[i].windowId = opened.id
            saving(&state, opened)
        }
        return opened
    }
}
