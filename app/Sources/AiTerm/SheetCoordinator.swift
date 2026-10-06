import Foundation
import AiTermCore

/// The sidebar's one sheet slot, and every way into it: what is presented, the preparation still
/// on its way to the slot, and the models the New Task and New Review sheets are opened with.
///
/// New Task, New Review, Settings — and New Terminal before the checkout monitor's first pass —
/// read something off the main actor before they open, and the menu stays enabled meanwhile. Two
/// rules keep a late preparation from replacing what the person opened since: every presentation
/// cancels the preparation still pending, and a preparation that finishes fills the slot only if it
/// is still empty.
@MainActor
@Observable
final class SheetCoordinator {
    typealias SheetKind = AppController.SheetKind

    var sheet: SheetKind?
    /// The preparation on its way to the slot, if any; tests await it.
    @ObservationIgnored private(set) var preparingSheet: Task<Void, Never>?

    private let workspace: WorkspaceStore
    private let checkouts: CheckoutMonitor
    private let agents: AgentIntegrations
    private let git: any GitRunning
    /// The home whose agent configuration the sheets read — models, skills, commands. The
    /// person's own in the app; a test's is a bare directory of its own.
    private let harnessHome: URL
    /// Read the saved Jira, GitLab and GitHub connections. Each reads the Keychain (Jira and GitLab
    /// also UserDefaults), so they are called off the main actor.
    private let jiraSettings: @Sendable () -> JiraConfig?
    private let gitLabSettings: @Sendable () -> GitLabConfig?
    private let gitHubSettings: @Sendable () -> GitHubConfig?
    /// What the creation sheets' Create runs.
    private let createTask: @MainActor (TaskDraft, Project) async throws -> Void
    private let createReview: @MainActor (ReviewDraft, Project) async throws -> Void

    init(workspace: WorkspaceStore, checkouts: CheckoutMonitor, agents: AgentIntegrations, git: any GitRunning, harnessHome: URL,
         jiraSettings: @escaping @Sendable () -> JiraConfig?,
         gitLabSettings: @escaping @Sendable () -> GitLabConfig?,
         gitHubSettings: @escaping @Sendable () -> GitHubConfig?,
         createTask: @escaping @MainActor (TaskDraft, Project) async throws -> Void,
         createReview: @escaping @MainActor (ReviewDraft, Project) async throws -> Void) {
        self.workspace = workspace
        self.checkouts = checkouts
        self.agents = agents
        self.git = git
        self.harnessHome = harnessHome
        self.jiraSettings = jiraSettings
        self.gitLabSettings = gitLabSettings
        self.gitHubSettings = gitHubSettings
        self.createTask = createTask
        self.createReview = createReview
    }

    private var canChangeWorkspace: Bool { workspace.canChangeWorkspace }
    private var state: AppState { workspace.state }

    /// Ends the preparation still pending, as the app shuts down.
    func cancelPreparation() {
        preparingSheet?.cancel()
        preparingSheet = nil
    }

    /// Puts `kind` in the sheet slot straight away, and ends any preparation still on its way to
    /// the slot: what the person opened since is the sheet they are typing into. The preparations
    /// check the slot is empty as they finish too, for a sheet put there by other means.
    private func present(_ kind: SheetKind) {
        cancelPreparation()
        sheet = kind
    }

    // -- sheets that open at once -------------------------------------------------------
    /// The sheet that edits the project's linked Jira projects, opened on the list as it is now.
    func presentJiraProjects(for project: Project) {
        guard canChangeWorkspace, let current = state.project(id: project.id) else { return }
        present(.jiraProjects(current))
    }

    func presentNewDivider() {
        guard canChangeWorkspace else { return }
        present(.newDivider)
    }

    func presentRename(divider: SidebarDivider) {
        guard canChangeWorkspace else { return }
        present(.rename(.divider(divider)))
    }

    func presentRename(task: TaskItem) {
        guard canChangeWorkspace else { return }
        present(.rename(.task(task)))
    }

    func presentRename(terminal: TerminalItem) {
        guard canChangeWorkspace, let current = state.terminal(id: terminal.id) else { return }
        present(.rename(.terminal(current)))
    }

    // -- sheets that read something first ----------------------------------------------
    /// Settings opens on the saved connections, read off the main actor: two Keychain items and
    /// UserDefaults, which can take a moment, and a Keychain that asks for access longer still.
    /// Off behind another sheet, as the zoom and view items are: Settings would replace it, and a
    /// New Task draft with it.
    var canPresentSettings: Bool { sheet == nil }

    /// Not through `present`, which replaces whatever is up: Settings is the one sheet the app menu
    /// (⌘,) reaches while another is up, so it refuses rather than take that sheet's place, and it
    /// is put in the slot only once its connections are read — if the slot is still empty then.
    func presentSettings() {
        guard canPresentSettings else { return }
        preparingSheet?.cancel()
        let jira = jiraSettings, gitLab = gitLabSettings, gitHub = gitHubSettings
        preparingSheet = Task {
            let saved = try? await BackgroundWork.run { (jira: jira(), gitLab: gitLab(), gitHub: gitHub()) }
            guard !Task.isCancelled, let saved, canPresentSettings else { return }
            sheet = .settings(jira: saved.jira, gitLab: saved.gitLab, gitHub: saved.gitHub)
        }
    }

    /// The New Terminal sheet, prefilled with the next free name. It asks for nothing else: the
    /// terminal opens in the project folder and starts no agent. The branch the destination line
    /// names is the project checkout's, as the checkout monitor read it on its last pass — the
    /// branch the terminal's row and tab titles will show — so the sheet opens at once. Before the
    /// monitor's first pass git is asked, off the main actor; the branch is read here rather than in
    /// the sheet, for the same reason `TaskDraft` is (see `SheetKind`): SwiftUI re-creates a
    /// sheet's root view on every state change of the presenting view.
    func presentNewTerminal(project: Project) {
        guard canChangeWorkspace, state.project(id: project.id) != nil else { return }
        if let branch = checkouts.projectBranch[project.id] {
            present(.newTerminal(project, name: state.suggestedTerminalName(in: project.id), branch: branch))
            return
        }
        preparingSheet?.cancel()
        let git = self.git
        preparingSheet = Task {
            let branch = try? await BackgroundWork.run { try git.run(["symbolic-ref", "--short", "HEAD"], in: project.path) }
            guard !Task.isCancelled, canChangeWorkspace, sheet == nil, state.project(id: project.id) != nil else { return }
            sheet = .newTerminal(project, name: state.suggestedTerminalName(in: project.id), branch: branch ?? "")
        }
    }

    /// Builds the draft once, here, and hands it to the sheet (see `SheetKind`): SwiftUI re-creates
    /// a sheet's root view on every state change of the presenting view, and a draft costs a read of
    /// the agent's model catalogue.
    func presentNewTask(project: Project) {
        // The monitor reads each project's default branch on every pass: nothing to ask git for.
        let git = self.git, known = checkouts.defaultBranch[project.id]
        prepareSheet(for: project, draft: { TaskDraft.initial(project: project, state: $0, git: git, agent: $1, catalog: $2, defaultBranch: known) },
                     search: jiraSettings) { [unowned self] in
            .newTask(makeCreationModel(project: project, draft: $0, catalogue: $1, catalogueFailure: $2, jira: $3))
        }
    }

    func presentNewReview(project: Project) {
        let gitLab = gitLabSettings, gitHub = gitHubSettings
        prepareSheet(for: project, draft: { ReviewDraft.initial(state: $0, agent: $1, catalog: $2) },
                     search: { (gitLab: gitLab(), gitHub: gitHub(),
                                remote: ProviderDetector.detect(remoteUrl: project.remoteUrl, repoPath: project.path)) }) { [unowned self] in
            .newReview(makeReviewModel(project: project, draft: $0, catalogue: $1, catalogueFailure: $2,
                                       gitLab: $3.gitLab, gitHub: $3.gitHub, remote: $3.remote))
        }
    }

    /// The remembered agent may be one that is no longer installed, so the draft falls back to an
    /// available one — the sheet's picker disables the missing ones and says why. The agent's
    /// catalogue is read for the draft and handed to the sheet's model with it — and why it has no
    /// models, when it could not be read, so the sheet neither reads it again nor launches a
    /// failing PI a second time.
    /// `search` is read here too — what the sheet's search needs from the Keychain and the
    /// checkout — so no keystroke has to.
    private func prepareSheet<Draft, Search>(for project: Project,
                                             draft build: @escaping @Sendable (AppState, AgentKind, [AgentModel]) -> Draft,
                                             search resolve: @escaping @Sendable () -> Search,
                                             sheet makeSheet: @escaping (Draft, [AgentModel], String?, Search) -> SheetKind)
        where Draft: AgentDraft & Sendable, Search: Sendable {
        guard canChangeWorkspace else { return }
        preparingSheet?.cancel()
        let state = self.state, available = agents.availableAgents, catalogue = agents.catalogue
        let agent = AgentAvailability.agent(preferring: state.lastAgentByProject[project.id] ?? .claude, available: available)
        preparingSheet = Task {
            let prepared = try? await BackgroundWork.run {
                let read = Result { try catalogue.models(for: agent) }
                let catalog = (try? read.get()) ?? []
                var failure: String?
                if case .failure(let error) = read { failure = error.localizedDescription }
                return (draft: build(state, agent, catalog), catalog: catalog, failure: failure, search: resolve())
            }
            guard !Task.isCancelled, canChangeWorkspace, sheet == nil, let prepared,
                  self.state.project(id: project.id) != nil else { return }
            sheet = makeSheet(prepared.draft, prepared.catalog, prepared.failure, prepared.search)
        }
    }

    // -- the creation sheets' models -----------------------------------------------------
    /// `catalogue` is the one `draft` was built from, if the caller read it, and `catalogueFailure`
    /// why it is empty if reading it failed; `jira` is the connection read when the sheet was prepared.
    func makeCreationModel(project: Project, draft: TaskDraft, catalogue: [AgentModel]? = nil, catalogueFailure: String? = nil,
                           jira: JiraConfig?) -> TaskCreationModel {
        let models = agents.catalogue, createTask = self.createTask
        return TaskCreationModel(project: project, draft: draft, home: harnessHome, availableAgents: { [agents] in agents.availableAgents },
                          rememberedModels: state.lastModelByAgent,
                          catalogue: { try models.models(for: $0) }, initialCatalogue: catalogue,
                          initialCatalogueFailure: catalogueFailure, git: git,
                          canChangeWorkspace: { [weak workspace] in workspace?.canChangeWorkspace == true },
                          searchIssues: TaskCreationModel.jiraSearcher(for: project, jira: jira),
                          createTask: { try await createTask($0, project) })
    }

    private func makeReviewModel(project: Project, draft: ReviewDraft, catalogue: [AgentModel]? = nil, catalogueFailure: String? = nil,
                                 gitLab: GitLabConfig?, gitHub: GitHubConfig?, remote: RemoteInfo) -> ReviewCreationModel {
        let models = agents.catalogue, createReview = self.createReview
        return ReviewCreationModel(project: project, draft: draft, home: harnessHome, availableAgents: { [agents] in agents.availableAgents },
                            rememberedModels: state.lastModelByAgent,
                            catalogue: { try models.models(for: $0) }, initialCatalogue: catalogue,
                            initialCatalogueFailure: catalogueFailure, git: git,
                            canChangeWorkspace: { [weak workspace] in workspace?.canChangeWorkspace == true },
                            owningTask: { [weak workspace] branch, checkouts in
                                workspace?.state.task(checkingOut: branch, in: project.id, worktrees: checkouts)
                            },
                            codeHost: MergeRequestSearch.host(for: remote),
                            searchMergeRequests: ReviewCreationModel.searcher(gitLab: gitLab, gitHub: gitHub, remote: remote),
                            createReview: { try await createReview($0, project) })
    }
}
