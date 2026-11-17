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

    // -- adding and editing a project ---------------------------------------------------
    var presentAdd: @MainActor (String?) async -> Void = { _ in }
    func addProject() async { await presentAdd(nil) }
    func addProject(path picked: String) async { await presentAdd(picked) }
    func chooseProjectFolder() async -> URL? { await prompter.chooseFolder(prompt: "Add Project") }

    private struct AlreadyAdded: LocalizedError {
        var project: Project
        var errorDescription: String? { "\(project.name) is already in your projects" }
    }
    func prepareProject(path picked: String) async throws -> ProjectPreparation {
        let git = git
        let inspection = try await BackgroundWork.run { () throws -> (String?, String, String?) in
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: picked, isDirectory: &directory), directory.boolValue else {
                throw ActionUnavailable("Choose an existing folder.")
            }
            let top = try Repository.toplevel(of: picked, git: git), path = top ?? picked
            let remote = top == nil ? nil : Log.git.attempt("Reading the remote of \(path)") { try Repository(path, git: git).remoteUrl() }
            return (top, path, remote ?? nil)
        }
        try Task.checkCancellation()
        let (top, path, remote) = inspection
        if let existing = state.projects.first(where: { $0.path == path }) { throw AlreadyAdded(project: existing) }
        let provider = ProviderDetector.detect(remoteUrl: remote, repoPath: top == nil ? nil : path).provider
        let project = Project(id: UUID(), name: URL(fileURLWithPath: path).lastPathComponent, path: path,
                              provider: provider, remoteUrl: remote, addedAt: Date(), collapsed: false)
        var prepared = ProjectPreparation(project: project, pickedPath: picked)
        if provider != .none {
            do {
                let known = Set(state.tasks.map(\.worktreePath))
                let found = try await BackgroundWork.run { () throws -> ([Worktree], String) in
                    let repository = Repository(path, git: git)
                    return (try repository.managedWorktrees().filter { $0.branch != nil && !known.contains($0.path) },
                            try repository.detectDefaultBranch() ?? Repository.fallbackDefaultBranch)
                }
                try Task.checkCancellation()
                prepared.worktrees = found.0; prepared.defaultBranch = found.1
            } catch {
                try Task.checkCancellation()
                prepared.importIssue = OperationIssue(title: "Couldn’t check \(project.name) for worktrees to import.", error: error)
            }
        }
        return prepared
    }
    func reportAddFailure(_ error: any Error) async {
        guard canChangeWorkspace else { return }
        if let duplicate = error as? AlreadyAdded {
            await prompter.ask(AlertPrompt(message: duplicate.localizedDescription, detail: duplicate.project.path))
        } else { notices.report(OperationIssue(title: "Couldn’t add the project.", error: error)) }
    }
    func makeProjectSheet(_ preparation: ProjectPreparation, editing: Bool) -> ProjectSheetModel {
        ProjectSheetModel(preparation: preparation, editing: editing,
                          canChange: { [weak self] in
                              guard let self else { return false }
                              return self.canChangeWorkspace && (!editing || self.state.project(id: preparation.project.id) != nil)
                          }, inspect: { [weak self] path in
                              guard let self else { throw CancellationError() }
                              return try await self.prepareProject(path: path)
                          }, chooseFolder: { [weak self] in await self?.chooseProjectFolder() },
                          loadProjects: { [weak self] in
                              guard let self else { throw CancellationError() }
                              return try await self.loadJiraProjects()
                          }, commit: { [weak self] prepared, linked, imports in
                              guard let self, self.canChangeWorkspace else { throw ActionUnavailable("The workspace can’t change right now.") }
                              if editing {
                                  guard self.state.project(id: prepared.project.id) != nil else { throw ActionUnavailable("The project was removed.") }
                                  self.setJiraProjects(linked, on: prepared.project)
                                  guard self.workspace.flush() else { throw ActionUnavailable("The project couldn’t be saved.") }
                              } else { try await self.commitProject(prepared, linked: linked, imports: imports) }
                          })
    }
    private func commitProject(_ prepared: ProjectPreparation, linked: [JiraProjectRef], imports: Bool) async throws {
        guard canChangeWorkspace else { throw ActionUnavailable("The workspace can’t change right now.") }
        var project = prepared.project; project.jiraProjects = linked.linkedOnce
        if let existing = state.projects.first(where: { $0.path == project.path && $0.id != project.id }) { throw AlreadyAdded(project: existing) }
        if state.project(id: project.id) == nil { workspace.mutate { $0.append(project: project) } }
        else { workspace.mutate { $0.updateProject(id: project.id) { $0.jiraProjects = project.jiraProjects } } }
        guard workspace.flush() else { throw ActionUnavailable("The project couldn’t be saved.") }
        checkouts.refresh()
        if prepared.pickedPath != project.path { notices.showToast("Added \(project.name), the repository around the folder you picked.") }
        if let issue = prepared.importIssue { notices.report(issue) }
        guard imports else { return }
        let git = git, catalogue = agents.catalogue, projectPath = project.path
        let agent = state.lastAgentByProject[project.id] ?? .claude, remembered = state.lastModelByAgent[agent]
        do {
            // Read again on Add: worktrees and the default branch can change while the sheet is up.
            let snapshot = try await BackgroundWork.run { () throws -> ([Worktree], String, ModelPreference) in
                let repository = Repository(projectPath, git: git)
                return (try repository.managedWorktrees(), try repository.detectDefaultBranch() ?? Repository.fallbackDefaultBranch,
                        ModelSettings.resolve(for: agent, catalog: catalogue.read(agent).models, remembered: remembered))
            }
            guard !Task.isCancelled, canChangeWorkspace, state.project(id: project.id)?.path == project.path else { return }
            let known = Set(state.tasks.map(\.worktreePath))
            let imported = snapshot.0.compactMap { worktree -> TaskItem? in
                guard let branch = worktree.branch, !known.contains(worktree.path) else { return nil }
                return TaskItem(id: UUID(), projectId: project.id, title: branch, branch: branch, worktreePath: worktree.path,
                                baseBranch: snapshot.1, jira: nil, kind: worktree.importedKind, agent: agent, model: snapshot.2.model,
                                reasoning: snapshot.2.reasoning, firstPrompt: nil, appendTicket: true, createdAt: Date(), windowId: nil)
            }
            workspace.mutate { $0.tasks += imported }
        } catch {
            guard !Task.isCancelled, canChangeWorkspace, state.project(id: project.id) != nil else { return }
            notices.report(OperationIssue(title: "Couldn’t check \(project.name) for worktrees to import.", error: error))
        }
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
                                         failure: { .rebaseRefused($0, in: project.id) })
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

    /// Whether the project has a task, review or terminal row, anything to fold.
    func hasRows(_ project: Project) -> Bool {
        return state.tasks.contains(where: { $0.projectId == project.id && ($0.signalTask == nil || $0.signalTask?.takenOver == true) })
            || state.terminals.contains(where: { $0.projectId == project.id })
    }

    /// Stores Focus View's or List View's collapsed project states in one workspace change.
    /// Saves only if a state changed; a locked workspace refuses the change.
    @discardableResult
    func setCollapsed(_ layout: [UUID: Bool]) -> Bool {
        guard canChangeWorkspace else { return false }
        workspace.mutate { state in
            for (id, collapsed) in layout {
                if let index = state.signals.firstIndex(where: { $0.id == id }) { state.signals[index].collapsed = collapsed }
                else { state.updateProject(id: id) { if $0.collapsed != collapsed { $0.collapsed = collapsed } } }
            }
        }
        return true
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
    /// Plan self-review: removing a project only forgets it. Worktrees created for its
    /// tasks stay on disk — the alert says so, and how many tasks go — and no git command runs.
    func confirmRemove(project: Project) async {
        guard canChangeWorkspace else { return }
        if let busy = busyReason(of: project) { return await refuseRemoval(of: project, because: busy) }
        let tasks = state.tasks.filter { $0.projectId == project.id }
        let held = tasks.filter { $0.signalTask.map { !$0.takenOver } == true && $0.hasCheckout }.count
        let answer = await prompter.ask(AlertPrompt(
            message: "Remove project “\(project.name)”?",
            detail: Self.removalDetail(tasks: tasks.count, archived: state.archived(projectId: project.id), operatorWorktrees: held),
            buttons: ["Remove", "Cancel"]))
        // Anything can run across the await, a create in the project among them, so it is asked
        // again — and the answer acted on in the same turn, with nothing able to start in between.
        guard answer.confirmed, canChangeWorkspace else { return }
        if let busy = busyReason(of: project) { return await refuseRemoval(of: project, because: busy) }
        workspace.mutate { $0.removeProject(id: project.id) }
    }

    /// The Remove Project alert says which tasks and Archive rows AiTerm forgets and what stays on disk.
    /// Archive never changes git, so forgetting an archived row loses only AiTerm's memory of it.
    static func removalDetail(tasks: Int, archived: [ArchivedTask], operatorWorktrees: Int = 0) -> String {
        let forgets: String
        switch archived.count {
        case 0: forgets = ""
        case 1: forgets = ", and forgets its archived \(archived[0].task.kindName.lowercased())"
        default: forgets = ", and forgets its \(archived.count) archived tasks and reviews"
        }
        if tasks == 0 { return "Removes the project from AiTerm\(forgets). Files are kept and terminal windows stay open." }
        let kept = archived.isEmpty ? "Files, worktrees and windows are kept." : "Files, branches, worktrees and windows are kept."
        let held = operatorWorktrees == 0 ? "" : " " + "\(operatorWorktrees) worktrees are run by signals."
        return "Removes the project and its \(tasks == 1 ? "task" : "\(tasks) tasks") from AiTerm\(forgets). \(kept)\(held)"
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
        // An archived row's archive, restore or removal lands back in its project, or saves a row whose
        // project would be gone.
        if state.archived(projectId: project.id).contains(where: { work.operation(onTask: $0.id) != nil }) {
            return "One of its archived tasks is still being archived, restored or removed."
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
