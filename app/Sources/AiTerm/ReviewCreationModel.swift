import Foundation
import AiTermCore

/// The New Review sheet's state: a `CreationModel` that searches the project's open merge requests.
final class ReviewCreationModel: CreationModel<ReviewDraft, MergeRequest> {
    /// Whose requests the sheet lists: it names them in its copy and draws their mark.
    let codeHost: CodeHost
    private let findOwner: (String, [Worktree]) -> TaskItem?

    /// What git reports checked out in the repository — which worktree has which branch. Read off
    /// the main actor when the sheet opens and again just before creating, never on a render.
    @Published private(set) var checkouts: [Worktree] = [] {
        didSet { findOwningTask() }
    }

    /// The row this review would open in, because its worktree has the branch checked out now:
    /// follows the draft's branch as it is picked, against the last `checkouts` read. Found when
    /// either changes rather than on each read: the lookup reads the workspace, and a render that
    /// did it would redraw the sheet on every change to the workspace.
    @Published private(set) var owningTask: TaskItem?

    override var draft: ReviewDraft {
        didSet { if draft.branch != oldValue.branch { findOwningTask() } }
    }

    // Ruling 3: `searchMergeRequests` is required. A default that silently returned no merge
    // requests would make a misconfigured sheet look merely empty rather than broken, and every
    // real call site passes `ReviewCreationModel.searcher(gitLab:gitHub:remote:)` anyway.
    /// `home` and `catalogue` have no defaults: each reads an agent's configuration, and a default
    /// would read the developer's own from anything that left them out.
    init(project: Project, draft: ReviewDraft, home: URL, availableAgents: Set<AgentKind> = Set(AgentKind.allCases),
         rememberedModels: [AgentKind: String] = [:],
         catalogue: @escaping @Sendable (AgentKind) -> [AgentModel],
         initialCatalogue: [AgentModel]? = nil,
         defaults: UserDefaults = .standard, git: any GitRunning,
         canChangeWorkspace: @escaping @MainActor () -> Bool = { true },
         owningTask: @escaping (_ branch: String, _ checkouts: [Worktree]) -> TaskItem? = { _, _ in nil },
         codeHost: CodeHost = .gitLab,
         searchMergeRequests: @escaping @MainActor (String) async throws -> [MergeRequest],
         createReview: @escaping @MainActor (ReviewDraft) async throws -> Void) {
        self.codeHost = codeHost
        self.findOwner = owningTask
        super.init(project: project, draft: draft, home: home, availableAgents: availableAgents, rememberedModels: rememberedModels,
                   catalogue: catalogue, initialCatalogue: initialCatalogue, defaults: defaults, git: git, canChangeWorkspace: canChangeWorkspace,
                   search: searchMergeRequests, submit: createReview)
        findOwningTask()
    }

    private func findOwningTask() {
        let owner = findOwner(draft.branch, checkouts)
        if owner != owningTask { owningTask = owner }
    }

    /// The worktree directory the sheet names: the one create will make.
    var worktreeSlug: String { unusedSlug(TaskCreator.reviewSlug(branch: draft.branch)) }

    func loadCheckouts() async {
        let path = project.path
        let git = git
        let found = try? await BackgroundWork.run { try Worktrees.listed(repo: path, git: git) }
        guard !Task.isCancelled else { return }
        checkouts = found ?? []
    }

    /// The sheet names where the review opens before anything is created, so it re-reads git first:
    /// if the branch has moved since — onto a task's worktree, or off one — it shows the new
    /// destination and waits for another press rather than opening somewhere it did not say.
    override func confirmBeforeSubmit() async -> Bool {
        let shown = owningTask
        await loadCheckouts()
        guard owningTask?.id == shown?.id else {
            let branch = draft.branch
            if let now = owningTask {
                refuse("\(branch) is now checked out in “\(now.title)”, so the review opens there. Press again to continue.")
            } else {
                refuse("“\(shown?.title ?? "The task")” no longer has \(branch) checked out, so the review gets a worktree of its own. Press again to continue.")
            }
            return false
        }
        return true
    }

    /// `gitLab`, `gitHub` and `remote` are the connections and the project's remote as they stood
    /// when the sheet was prepared: Keychain reads and a look at the checkout, too slow for every
    /// keystroke on the main actor, so a connection changed in Settings meanwhile applies from the
    /// next sheet. Only a GitHub remote searches GitHub; everything else is GitLab's as before,
    /// including a self-hosted GitLab the detector could only call plain git.
    static func searcher(gitLab: GitLabConfig?, gitHub: GitHubConfig? = nil, remote: RemoteInfo) -> @MainActor (String) async throws -> [MergeRequest] {
        { text in
            if remote.provider == .github {
                guard let config = gitHub else {
                    throw ActionUnavailable("Connect GitHub in Settings › Integrations, or pick a branch instead.")
                }
                guard !remote.path.isEmpty else {
                    throw ActionUnavailable("Couldn’t read a GitHub repository from this repository’s remote.")
                }
                return try await GitHubClient(config: config).pullRequests(repo: remote.path, search: text)
            }
            guard let config = gitLab else {
                throw ActionUnavailable("Connect GitLab in Settings › Integrations, or pick a branch instead.")
            }
            // One GitLab host is configured. A project whose remote points elsewhere says so
            // rather than listing another project's merge requests.
            guard let host = remote.host, host == config.hostURL.host?.lowercased() else {
                throw ActionUnavailable("This project’s remote is \(remote.host ?? "not a GitLab host"); GitLab is configured for \(config.hostURL.host ?? "another host").")
            }
            guard !remote.path.isEmpty else {
                throw ActionUnavailable("Couldn’t read a GitLab project path from this repository’s remote.")
            }
            return try await GitLabClient(config: config).mergeRequests(project: remote.path, search: text)
        }
    }

    /// Why the last pick was refused. Apart from `searchError`: the picker clears its query after a
    /// pick, which re-searches, and a search that succeeds clears `searchError`.
    @Published private(set) var pickRefusal: String?

    /// A fork's branch is not on origin, which is where a review's worktree checks out from, so a
    /// fork's pull request is refused with the fork named rather than failing at Create.
    func pick(_ mr: MergeRequest) {
        if let fork = mr.forkHead {
            pickRefusal = "This pull request’s branch is in a fork (\(fork)). AiTerm reviews branches on origin."
            return
        }
        pickRefusal = nil
        cancelSearch()
        searchError = nil
        draft.apply(mr: mr)
    }

    /// The sheet's clear action on a picked request.
    func clearPick() {
        pickRefusal = nil
        draft.apply(mr: nil)
    }

    /// What the branch field has typed, and the branches it matches. Filtered when either changes
    /// rather than on each read: the sheet reads the matches on every render, and a repository can
    /// have hundreds of branches.
    @Published var branchQuery = "" {
        didSet { if branchQuery != oldValue { filterBranches() } }
    }
    @Published private(set) var branchMatches: [String] = []

    override var branches: [String] {
        didSet { filterBranches() }
    }

    private func filterBranches() {
        let matches = filteredBranches(query: branchQuery)
        if matches != branchMatches { branchMatches = matches }
    }

    /// A popup of every branch in a real repository is unusable, so the branch field filters by
    /// substring instead — case-insensitively, order preserved (default branch first).
    func filteredBranches(query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return branches }
        return branches.filter { $0.range(of: q, options: .caseInsensitive) != nil }
    }
}
