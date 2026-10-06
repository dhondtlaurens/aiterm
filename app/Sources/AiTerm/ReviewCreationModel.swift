import Foundation
import AiTermCore

/// New Review's part of `CreationModel`: it searches the project's open merge requests, follows
/// which task already has the branch checked out, and filters the branch list as it is typed. Its
/// state is read through `ReviewCreationModel`, which keeps it current.
@MainActor
@Observable
final class ReviewCreation: CreationKind {
    typealias Draft = ReviewDraft
    typealias Item = MergeRequest

    /// Whose requests the sheet lists: it names them in its copy and draws their mark.
    let codeHost: CodeHost
    fileprivate let findOwner: (String, [Worktree]) -> TaskItem?
    fileprivate(set) var checkouts: [Worktree] = []
    fileprivate(set) var owningTask: TaskItem?
    fileprivate(set) var pickRefusal: String?
    fileprivate(set) var branchQuery = ""
    fileprivate(set) var branchMatches: [String] = []

    init(codeHost: CodeHost, findOwner: @escaping (String, [Worktree]) -> TaskItem?) {
        self.codeHost = codeHost; self.findOwner = findOwner
    }

    func slug(for draft: ReviewDraft) -> String { BranchNaming.reviewSlug(branch: draft.branch) }

    func draftChanged(from old: ReviewDraft, in model: ReviewCreationModel) {
        if model.draft.branch != old.branch { model.findOwningTask() }
    }

    func branchesChanged(in model: ReviewCreationModel) { model.filterBranches() }

    /// The sheet names where the review opens before anything is created, so it re-reads git first:
    /// if the branch has moved since — onto a task's worktree, or off one — it shows the new
    /// destination and waits for another press rather than opening somewhere it did not say.
    func confirmBeforeSubmit(_ model: ReviewCreationModel) async -> Bool {
        let shown = owningTask
        await model.loadCheckouts()
        guard owningTask?.id == shown?.id else {
            let branch = model.draft.branch
            if let now = owningTask {
                model.refuse("\(branch) is now checked out in “\(now.title)”, so the review opens there. Press again to continue.")
            } else {
                model.refuse("“\(shown?.title ?? "The task")” no longer has \(branch) checked out, so the review gets a worktree of its own. Press again to continue.")
            }
            return false
        }
        return true
    }
}

/// The New Review sheet's state.
typealias ReviewCreationModel = CreationModel<ReviewCreation>

extension CreationModel where Kind == ReviewCreation {
    // `searchMergeRequests` is required. A default that silently returned no merge
    // requests would make a misconfigured sheet look merely empty rather than broken, and every
    // real call site passes `ReviewCreationModel.searcher(gitLab:gitHub:remote:)` anyway.
    /// `home` and `catalogue` have no defaults: each reads an agent's configuration, and a default
    /// would read the developer's own from anything that left them out. A `catalogue` that throws
    /// has no models to offer, and the sheet says why in their place.
    convenience init(project: Project, draft: ReviewDraft, home: URL,
                     availableAgents: @escaping @MainActor () -> Set<AgentKind> = { Set(AgentKind.allCases) },
                     rememberedModels: [AgentKind: String] = [:],
                     catalogue: @escaping @Sendable (AgentKind) throws -> [AgentModel],
                     initialCatalogue: [AgentModel]? = nil, initialCatalogueFailure: String? = nil,
                     defaults: UserDefaults = .standard, git: any GitRunning,
                     canChangeWorkspace: @escaping @MainActor () -> Bool = { true },
                     owningTask: @escaping (_ branch: String, _ checkouts: [Worktree]) -> TaskItem? = { _, _ in nil },
                     codeHost: CodeHost = .gitLab,
                     searchMergeRequests: @escaping @MainActor (String) async throws -> [MergeRequest],
                     createReview: @escaping @MainActor (ReviewDraft) async throws -> Void) {
        self.init(kind: ReviewCreation(codeHost: codeHost, findOwner: owningTask), project: project, draft: draft, home: home,
                  availableAgents: availableAgents, rememberedModels: rememberedModels, catalogue: catalogue,
                  initialCatalogue: initialCatalogue, initialCatalogueFailure: initialCatalogueFailure, defaults: defaults,
                  git: git, canChangeWorkspace: canChangeWorkspace, search: searchMergeRequests, submit: createReview)
        findOwningTask()
    }

    var codeHost: CodeHost { kind.codeHost }

    /// What git reports checked out in the repository — which worktree has which branch. Read off
    /// the main actor when the sheet opens and again just before creating, never on a render.
    var checkouts: [Worktree] { kind.checkouts }

    /// The row this review would open in, because its worktree has the branch checked out now:
    /// follows the draft's branch as it is picked, against the last `checkouts` read. Found when
    /// either changes rather than on each read: the lookup reads the workspace, and a render that
    /// did it would redraw the sheet on every change to the workspace.
    var owningTask: TaskItem? { kind.owningTask }

    fileprivate func findOwningTask() {
        kind.owningTask = kind.findOwner(draft.branch, kind.checkouts)
    }

    func loadCheckouts() async {
        let path = project.path
        let git = git
        // Unknown, no checkout is found to own the branch, and git refuses the review's own if one does.
        let found = await Log.git.attempt("Listing the worktrees of \(path)") {
            try await BackgroundWork.run { try Repository(path, git: git).worktrees() }
        }
        guard !Task.isCancelled else { return }
        kind.checkouts = found ?? []
        findOwningTask()
    }

    /// `gitLab`, `gitHub` and `remote` are the connections and the project's remote as they stood
    /// when the sheet was prepared: Keychain reads and a look at the checkout, too slow for every
    /// keystroke on the main actor, so a connection changed in Settings meanwhile applies from the
    /// next sheet. Which host is searched is Core's to say (`MergeRequestSearch`); why none can be
    /// is the sheet's search error, on every search.
    static func searcher(gitLab: GitLabConfig?, gitHub: GitHubConfig? = nil, remote: RemoteInfo) -> @MainActor (String) async throws -> [MergeRequest] {
        let source = Result(catching: { () throws(MergeRequestSearch.Unavailable) -> any MergeRequestSearching in
            try MergeRequestSearch.source(for: remote, gitLab: gitLab, gitHub: gitHub)
        })
        return { text in
            switch source {
            case .success(let search): return try await search.mergeRequests(search: text)
            case .failure(let unavailable): throw ActionUnavailable(unavailable.message)
            }
        }
    }

    /// Why the last pick was refused. Apart from `searchError`: the picker clears its query after a
    /// pick, which re-searches, and a search that succeeds clears `searchError`.
    var pickRefusal: String? { kind.pickRefusal }

    /// A fork's branch is not on origin, which is where a review's worktree checks out from, so a
    /// fork's pull request is refused with the fork named rather than failing at Create.
    func pick(_ mr: MergeRequest) {
        if let fork = mr.forkHead {
            kind.pickRefusal = "This pull request’s branch is in a fork (\(fork)). AiTerm reviews branches on origin."
            return
        }
        kind.pickRefusal = nil
        cancelSearch()
        searchError = nil
        draft.apply(mr: mr)
    }

    /// The sheet's clear action on a picked request.
    func clearPick() {
        kind.pickRefusal = nil
        draft.apply(mr: nil)
    }

    /// What the branch field has typed, and the branches it matches. Filtered when either changes
    /// rather than on each read: the sheet reads the matches on every render, and a repository can
    /// have hundreds of branches.
    var branchQuery: String {
        get { kind.branchQuery }
        set {
            guard newValue != kind.branchQuery else { return }
            kind.branchQuery = newValue
            filterBranches()
        }
    }
    var branchMatches: [String] { kind.branchMatches }

    fileprivate func filterBranches() {
        kind.branchMatches = filteredBranches(query: branchQuery)
    }

    /// A popup of every branch in a real repository is unusable, so the branch field filters by
    /// substring instead — case-insensitively, order preserved (default branch first).
    func filteredBranches(query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return branches }
        return branches.filter { $0.range(of: q, options: .caseInsensitive) != nil }
    }
}

extension MergeRequestSearch.Unavailable {
    /// What the sheet says in place of merge requests.
    var message: String {
        switch self {
        case .notConnected(let host): "Connect \(host.name) in Settings › Integrations, or pick a branch instead."
        case .noRepositoryPath(.gitHub): "Couldn’t read a GitHub repository from this repository’s remote."
        case .noRepositoryPath(.gitLab): "Couldn’t read a GitLab project path from this repository’s remote."
        case .otherGitLabHost(let remote, let configured):
            "This project’s remote is \(remote ?? "not a GitLab host"); GitLab is configured for \(configured ?? "another host")."
        }
    }
}
