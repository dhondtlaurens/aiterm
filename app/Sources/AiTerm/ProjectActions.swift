import Foundation
import AiTermCore

/// The projects and the sidebar's other items, and every edit to them: a project added — with the
/// offer to import its worktrees — or removed, a remote adopted, Jira projects linked, the default
/// branch pulled or rebased, a project folded or moved; dividers added, renamed and removed; a task
/// or a terminal renamed. Each is a change to the workspace and nothing else, but for git's own
/// reads and the pull.
@MainActor
final class ProjectActions {
    private let workspace: WorkspaceStore
    private let work: WorkInFlight
    private let notices: Notices
    private let prompter: Prompter
    private let checkouts: CheckoutMonitor
    /// The agent catalogue an imported worktree's task takes its model from.
    private let agents: AgentIntegrations
    private let git: any GitRunning
    private let workflow: TaskWorkflow
    /// Reads the saved Jira connection — the Keychain and UserDefaults — off the main actor, for a
    /// project's Jira projects sheet.
    private let jiraSettings: @Sendable () -> JiraConfig?
    /// Whether each project's default branch is being pulled or rebased, observed row by row: the
    /// project's Pull greys while either runs.
    private let defaultBranchRows: PerRow<Bool>

    init(workspace: WorkspaceStore, work: WorkInFlight, notices: Notices, prompter: Prompter, checkouts: CheckoutMonitor,
         agents: AgentIntegrations, git: any GitRunning, workflow: TaskWorkflow,
         jiraSettings: @escaping @Sendable () -> JiraConfig?) {
        self.workspace = workspace
        self.work = work
        self.notices = notices
        self.prompter = prompter
        self.checkouts = checkouts
        self.agents = agents
        self.git = git
        self.workflow = workflow
        self.jiraSettings = jiraSettings
        let defaultBranchRows = PerRow<Bool>(default: false, workspace: workspace)
        self.defaultBranchRows = defaultBranchRows
        // Unowned: the ledger holds the hook.
        work.onChange { [unowned work] subject in
            if case .project(let id) = subject { defaultBranchRows[id] = work.isRunning(.changingDefaultBranch, onProject: id) }
        }
        // Each pass's remotes, adopted where a project's has changed since it was added.
        checkouts.onRemotes { [weak workspace] detected in workspace?.mutate { $0.adoptRemotes(detected) } }
    }

    private var canChangeWorkspace: Bool { workspace.canChangeWorkspace }
    private var state: AppState { workspace.state }

    // -- adding a project ---------------------------------------------------------------
    /// The folder chooser adds the project at once: its Jira projects are linked afterwards, from
    /// the project's context menu, and none linked means New Task searches every Jira project.
    /// Whether the workspace can still change once a folder is picked is `addProject(path:)`'s
    /// first question.
    func addProject() async {
        guard canChangeWorkspace, let url = await prompter.chooseFolder(prompt: "Add Project") else { return }
        await addProject(path: url.path)
    }

    /// The repository a picked folder belongs to, added with its remote, then the offer to import
    /// its worktrees. A folder inside a repository adds the repository itself, and a toast says so;
    /// one already in the workspace is refused. A git that cannot say whether the folder is in a
    /// repository at all — it timed out, or would not start — adds nothing, and the banner says so.
    func addProject(path picked: String) async {
        guard canChangeWorkspace else { return }
        let git = self.git
        let inspection: (toplevel: String?, path: String, remote: String?)
        do {
            inspection = try await BackgroundWork.run {
                let top = try Repository.toplevel(of: picked, git: git)
                let path = top ?? picked
                // A lookup that fails adds the project without a remote, which the checkout monitor's
                // next pass finds and adopts; it is not worth refusing the folder over, nor telling
                // anyone about. Its worktrees are still offered: a repository is `.git` without one.
                let remote = top == nil ? nil : Log.git.attempt("Reading the remote of \(path)") { try Repository(path, git: git).remoteUrl() }
                return (top, path, remote ?? nil)
            }
        } catch {
            Log.workspace.failed("Inspecting \(picked) to add it as a project", error)
            if canChangeWorkspace { notices.report(OperationIssue(title: "Couldn’t add the project.", error: error)) }
            return
        }
        guard canChangeWorkspace else { return }
        let (toplevel, path, remote) = inspection
        if let existing = state.projects.first(where: { $0.path == path }) {
            await prompter.ask(AlertPrompt(message: "\(existing.name) is already in your projects", detail: existing.path))
            return
        }
        let provider = ProviderDetector.detect(remoteUrl: remote, repoPath: toplevel == nil ? nil : path).provider
        let project = Project(id: UUID(), name: URL(fileURLWithPath: path).lastPathComponent, path: path,
                              provider: provider, remoteUrl: remote, addedAt: Date(), collapsed: false)
        workspace.mutate { $0.append(project: project) }
        // Its worktrees are offered for import once it is saved, and not at all if it cannot be.
        guard workspace.flush() else { return }
        checkouts.refresh()
        if let toplevel, toplevel != picked { notices.showToast("Added \(project.name), the repository around the folder you picked.") }
        await importWorktrees(for: project)
    }

    private func importWorktrees(for project: Project) async {
        guard project.provider != .none else { return }
        let git = self.git, catalogue = agents.catalogue
        let agent = state.lastAgentByProject[project.id] ?? .claude
        let remembered = state.lastModelByAgent[agent]
        let imports: (found: [Worktree], detected: String?, preference: ModelPreference)
        do {
            imports = try await BackgroundWork.run {
                let repository = Repository(project.path, git: git)
                return (try repository.managedWorktrees(), try repository.detectDefaultBranch(),
                        ModelSettings.resolve(for: agent, catalog: catalogue.read(agent).models, remembered: remembered))
            }
        } catch {
            // A default branch git could not be asked for throws above, and nothing is offered: the
            // offer is made only when the project is added, so it is not made at all rather than
            // saving "main" into every imported task for a timeout — and the banner says it was not,
            // unless no import could have been made by now anyway. A repository with no default
            // branch to name is another matter.
            Log.git.failed("Looking for worktrees to import into \(project.path)", error)
            guard canChangeWorkspace, state.project(id: project.id) != nil else { return }
            notices.report(OperationIssue(title: "Couldn’t check \(project.name) for worktrees to import.", error: error))
            return
        }
        let (found, detected, preference) = imports
        guard canChangeWorkspace, state.project(id: project.id) != nil, !found.isEmpty else { return }
        let base = detected ?? Repository.fallbackDefaultBranch
        let answer = await prompter.ask(AlertPrompt(message: "Import \(found.count) worktree\(found.count == 1 ? "" : "s")?",
                                              detail: "Adds existing worktrees as tasks without starting agents.",
                                              buttons: ["Import", "Skip"], escape: 1))
        // Anything can run across the await, and the project can have gone.
        guard answer.confirmed, canChangeWorkspace, state.project(id: project.id) != nil else { return }
        let known = Set(state.tasks.map(\.worktreePath))
        let imported = found.compactMap { worktree -> TaskItem? in
            guard let branch = worktree.branch, !known.contains(worktree.path) else { return nil }
            return TaskItem(id: UUID(), projectId: project.id, title: branch, branch: branch,
                     worktreePath: worktree.path, baseBranch: base, jira: nil, kind: worktree.importedKind,
                     agent: agent, model: preference.model,
                     reasoning: preference.reasoning, firstPrompt: nil, appendTicket: true, createdAt: Date(), windowId: nil)
        }
        workspace.mutate { $0.tasks += imported }
    }

    // -- Jira -----------------------------------------------------------------------------
    /// The connection is a Keychain read, so it is made off the main actor.
    func loadJiraProjects() async throws -> [JiraProjectRef] {
        guard let config = await BackgroundWork.run(jiraSettings) else {
            throw ActionUnavailable("Connect Jira in Settings › Integrations to choose a Jira project.")
        }
        return try await JiraClient(config: config).projects()
    }

    /// Replaces the project's linked Jira projects with `jiraProjects`, each once, in their order.
    /// An empty list unlinks them all.
    func setJiraProjects(_ jiraProjects: [JiraProjectRef], on project: Project) {
        let linked = jiraProjects.linkedOnce
        guard canChangeWorkspace, let current = state.project(id: project.id),
              current.jiraProjects != linked else { return }
        workspace.mutate { $0.updateProject(id: project.id) { $0.jiraProjects = linked } }
    }

    // -- the default branch -----------------------------------------------------------------
    /// Whether the project's default branch is being pulled or rebased, as its menu reads it.
    func isChangingDefaultBranch(_ projectId: UUID) -> Bool { defaultBranchRows[projectId] }

    /// "Pull main": the project's default branch brought to origin's, fast-forward only. Git's
    /// own state, not the workspace's, so a locked workspace does not stop it.
    @discardableResult
    func pullDefault(project: Project) -> Task<Void, Never>? {
        changeDefaultBranch(of: project, { [workflow] in try await workflow.pullDefaultBranch(of: project).toast },
                            failure: { .pullRefused($0, in: project.id) })
    }

    /// The banner's Rebase, after "Pull main" found the branches diverged. Held like a pull, so
    /// the menu's Pull main waits for it.
    func rebaseDefault(project: Project) -> Task<Void, Never>? {
        let rebase = changeDefaultBranch(of: project, { [workflow] in try await workflow.rebaseDefaultBranch(of: project).toast },
                                         failure: { OperationIssue(title: "Couldn’t rebase the default branch.", error: $0) })
        if rebase != nil { notices.clearIssue() }
        return rebase
    }

    /// A pull or a rebase of `project`'s default branch, one at a time: the result's `.toast` is the
    /// toast, its failure the banner. Neither is shown for a project removed while git ran.
    private func changeDefaultBranch(of project: Project, _ run: @escaping () async throws -> String,
                                     failure: @escaping (Error) -> OperationIssue) -> Task<Void, Never>? {
        guard let token = work.begin(.changingDefaultBranch, onProject: project.id) else { return nil }
        return Task {
            defer { work.end(token) }
            do {
                let summary = try await run()
                guard state.project(id: project.id) != nil else { return }
                notices.showToast(summary)
                checkouts.refresh()
            } catch {
                guard state.project(id: project.id) != nil else { return }
                notices.report(failure(error))
            }
        }
    }

    // -- folding and order ------------------------------------------------------------------
    /// A project with no task or terminal draws collapsed and stays that way (`ProjectSection.collapsed`),
    /// so it has no stored state worth flipping.
    func toggleCollapsed(_ project: Project) {
        guard canChangeWorkspace, state.project(id: project.id) != nil, hasRows(project) else { return }
        workspace.mutate { $0.updateProject(id: project.id) { $0.collapsed.toggle() } }
    }

    /// Whether the project has a task, review or terminal row — anything to fold.
    func hasRows(_ project: Project) -> Bool {
        state.tasks.contains(where: { $0.projectId == project.id })
            || state.terminals.contains(where: { $0.projectId == project.id })
    }

    /// Stores `layout`'s collapsed states — Focus View's or List View's — in one change to the
    /// workspace, which saves only if one changed. Whether it was stored: not in a locked workspace.
    @discardableResult
    func setCollapsed(_ layout: [UUID: Bool]) -> Bool {
        guard canChangeWorkspace else { return false }
        workspace.mutate { state in
            for (id, collapsed) in layout {
                state.updateProject(id: id) { if $0.collapsed != collapsed { $0.collapsed = collapsed } }
            }
        }
        return true
    }

    /// Whether `move` would do anything: the first row has no "up", the last no "down", and a
    /// locked workspace has neither. The menus grey their items on this.
    func canMove(itemId: UUID, _ step: MoveStep) -> Bool {
        canChangeWorkspace && state.canMove(id: itemId, step)
    }

    /// Moves a project or a divider one slot along the sidebar. Only the item order changes: tasks
    /// and terminals stay attached by project id, so an expanded project's rows move with it and
    /// its collapsed state is left untouched. Whether it moved.
    @discardableResult
    func move(itemId: UUID, _ step: MoveStep) -> Bool {
        guard canChangeWorkspace else { return false }
        return workspace.mutate { $0.move(id: itemId, step) }
    }

    // -- removing a project -----------------------------------------------------------------
    /// Plan self-review (spec 4.6): removing a project only forgets it. Worktrees created for its
    /// tasks stay on disk — the alert says so, and how many tasks go — and no git command runs.
    func confirmRemove(project: Project) async {
        guard canChangeWorkspace else { return }
        if let busy = busyReason(of: project) { return await refuseRemoval(of: project, because: busy) }
        let tasks = state.tasks.filter { $0.projectId == project.id }.count
        let answer = await prompter.ask(AlertPrompt(
            message: "Remove project “\(project.name)”?",
            detail: tasks == 0
                ? "Removes the project from AiTerm. Files are kept and terminal windows stay open."
                : "Removes the project and its \(tasks == 1 ? "task" : "\(tasks) tasks") from AiTerm. Files, worktrees and windows are kept.",
            buttons: ["Remove", "Cancel"]))
        // Anything can run across the await, a create in the project among them, so it is asked
        // again — and the answer acted on in the same turn, with nothing able to start in between.
        guard answer.confirmed, canChangeWorkspace else { return }
        if let busy = busyReason(of: project) { return await refuseRemoval(of: project, because: busy) }
        workspace.mutate { state in
            state.tasks.removeAll { $0.projectId == project.id }
            state.terminals.removeAll { $0.projectId == project.id }
            state.removeItem(id: project.id)
        }
    }

    /// Why `project` cannot be removed yet, if it cannot: work still in flight would land in a
    /// project that is gone, and a row whose project is gone fails every save. Synchronous, so the
    /// caller that finds nothing removes the project before anything else can start.
    private func busyReason(of project: Project) -> String? {
        if work.isRunning(.creatingTask, onProject: project.id) { return "A task is still being created in it." }
        if work.isRunning(.openingTerminal, onProject: project.id) { return "A terminal is still opening in it." }
        if work.isRunning(.openingTaskWindow, onProject: project.id) { return "A window is still opening for one of its tasks." }
        if state.terminals.contains(where: { $0.projectId == project.id && work.operation(onTerminal: $0.id) != nil }) {
            return "One of its terminals is still opening or closing its window."
        }
        if state.tasks.contains(where: { $0.projectId == project.id && work.operation(onTask: $0.id) != nil }) {
            return "A task is still being changed."
        }
        return nil
    }

    /// Tells the person that `project` cannot be removed yet, and why.
    private func refuseRemoval(of project: Project, because busy: String) async {
        await prompter.ask(AlertPrompt(message: "“\(project.name)” can’t be removed yet", detail: busy + " Try again in a moment."))
    }

    // -- dividers and renames ---------------------------------------------------------------
    /// A divider is pure workspace state: no daemon call, no window, nothing to undo but the label.
    func addDivider(name: String) {
        guard canChangeWorkspace else { return }
        let divider = SidebarDivider(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        workspace.mutate { $0.append(divider: divider) }
    }

    func removeDivider(_ divider: SidebarDivider) {
        guard canChangeWorkspace else { return }
        workspace.mutate { $0.removeItem(id: divider.id) }
    }

    /// An empty name is a real choice for a divider — the row draws a plain rule.
    func rename(divider: SidebarDivider, to name: String) {
        guard canChangeWorkspace else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        workspace.mutate { $0.renameDivider(id: divider.id, to: trimmed) }
    }

    /// The title only. The branch, worktree, base branch and Jira link are untouched, and the
    /// iTerm2 window keeps its own title — it carries the branch, not the task's name.
    func rename(task: TaskItem, to name: String) {
        guard canChangeWorkspace else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = state.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        workspace.mutate { $0.tasks[i].title = trimmed }
    }

    /// The row's name, and the one its window is opened with on Reopen. Nothing in iTerm2 changes:
    /// its tabs are titled with their branch (`SidebarModel.sessionTitles`), not with this name,
    /// and the window's profile name is set once, as it opens. An empty name keeps the old one.
    func rename(terminal: TerminalItem, to name: String) {
        guard canChangeWorkspace else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = state.terminals.firstIndex(where: { $0.id == terminal.id }) else { return }
        workspace.mutate { $0.terminals[i].name = trimmed }
    }
}
