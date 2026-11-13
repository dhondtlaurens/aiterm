import Foundation
import AiTermCore

/// What New Review's ticket field reads, and how it and the merge request field fill each other:
/// the ticket search (Jira and the repository's GitLab issues, as New Task's), a ticket's open
/// merge requests in this repository, and a merge request's ticket. Closures, so a test hands its
/// own; `init(project:jira:gitLab:gitHub:remote:)` makes the real ones from the connections read
/// when the sheet was prepared.
struct ReviewTicketLookup: Sendable {
    var search: @Sendable (String) async throws -> [JiraTicket]
    var requests: @Sendable (JiraTicket) async throws -> TicketMergeRequests.Found
    var ticket: @Sendable (MergeRequest) async throws -> JiraTicket?
    /// The repository a miss names: `jarvis/jarvis`.
    var repository: String
    var jiraConnected: Bool
    var jiraProjects: [String]

    /// No tickets anywhere: for a sheet that is not about them.
    static let none = ReviewTicketLookup(search: { _ in [] }, requests: { _ in .init(requests: [], complete: true) },
                                         ticket: { _ in nil }, repository: "", jiraConnected: false, jiraProjects: [])

    init(search: @escaping @Sendable (String) async throws -> [JiraTicket],
         requests: @escaping @Sendable (JiraTicket) async throws -> TicketMergeRequests.Found,
         ticket: @escaping @Sendable (MergeRequest) async throws -> JiraTicket?,
         repository: String, jiraConnected: Bool, jiraProjects: [String]) {
        self.search = search; self.requests = requests; self.ticket = ticket
        self.repository = repository; self.jiraConnected = jiraConnected; self.jiraProjects = jiraProjects
    }

    init(project: Project, jira: JiraConfig?, gitLab: GitLabConfig?, gitHub: GitHubConfig?, remote: RemoteInfo) {
        let jiraSource = TaskCreationModel.jiraSource(for: project, jira: jira)
        let issues = TaskCreationModel.gitLabIssueSource(gitLab: gitLab, remote: remote)
        let tickets = TicketSearch(jira: jiraSource, jiraUnavailable: TaskCreationModel.connectJira, gitLabIssues: issues)
        let repository = try? MergeRequestSearch.source(for: remote, gitLab: gitLab, gitHub: gitHub)
        let linked = project.jiraProjects
        self.init(
            search: { try await tickets.tickets(matching: $0) },
            requests: { ticket in
                guard let repository else { return .init(requests: [], complete: true) }
                return try await TicketMergeRequests.requests(for: ticket, in: repository)
            },
            ticket: { request in
                switch TicketMergeRequests.reference(of: request, issues: issues != nil) {
                case .gitLabIssue(let number)?:
                    return try await issues?("#\(number)").first
                case .jira(let key)?:
                    // A key from another project's prefix is a word that looks like one (`release-2026`).
                    guard let jiraSource, linked.isEmpty || linked.contains(where: { key.hasPrefix($0.key + "-") }) else { return nil }
                    return try await jiraSource(key).first { $0.key == key }
                case nil:
                    return nil
                }
            },
            repository: remote.path, jiraConnected: jira != nil, jiraProjects: linked.map(\.key))
    }
}

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
    fileprivate let fix: @MainActor (CreationFailure.Recovery) async throws -> Void
    fileprivate(set) var checkouts: [Worktree] = []
    fileprivate(set) var owningTask: TaskItem?
    fileprivate(set) var pickRefusal: String?
    fileprivate(set) var branchQuery = ""
    fileprivate(set) var branchMatches: [String] = []

    // The ticket field: its own search, as the merge request field's is `CreationModel`'s.
    fileprivate let tickets: ReviewTicketLookup
    /// The ticket field's search. Its typing cancels only its own typed search (`DebouncedSearch.Superseding`), as it
    /// did before it shared the pickers' type.
    fileprivate let ticketSearch: DebouncedSearch<JiraTicket>
    /// What the ticket's lookup said when it filled nothing: several requests, none, or none among
    /// those it read. Shown under the merge request field.
    var ticketLookupNote: String?
    /// Bumped when the lookup found several requests and the merge request list should open on them.
    fileprivate(set) var requestListOffers = 0
    /// The lookup in flight, if any: a newer pick cancels it, and a test awaits it.
    @ObservationIgnored var lookupTask: Task<Void, Never>?

    init(codeHost: CodeHost, findOwner: @escaping (String, [Worktree]) -> TaskItem?,
         fix: @escaping @MainActor (CreationFailure.Recovery) async throws -> Void, tickets: ReviewTicketLookup = .none) {
        self.codeHost = codeHost; self.findOwner = findOwner; self.fix = fix; self.tickets = tickets
        ticketSearch = DebouncedSearch(superseding: .typedSearchOnly) { try await tickets.search($0) }
    }

    /// The reviewer's prompt carries the ticket too, when step 3's checkbox was kept.
    func composedPrompt(_ text: String, draft: ReviewDraft) -> String? {
        AgentCommand.composePrompt(userText: text, ticket: draft.ticket, appendTicket: draft.appendTicket)
    }

    func slug(for draft: ReviewDraft) -> String { BranchNaming.reviewSlug(branch: draft.branch) }

    func draftChanged(from old: ReviewDraft, in model: ReviewCreationModel) {
        guard model.draft.branch != old.branch else { return }
        model.findOwningTask()
        // A refusal, its Rebase and its Fix were all about the branch the draft has just left.
        model.dropFailure()
    }

    func fixApplies(_ request: FixRequest, to draft: ReviewDraft) -> Bool { request.branch == draft.branch }

    func branchesChanged(in model: ReviewCreationModel) { model.filterBranches() }

    func recover(_ recovery: CreationFailure.Recovery) async throws { try await fix(recovery) }

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
    // real call site passes `ReviewCreationModel.searcher(gitLab:gitHub:remote:)` anyway. So is
    // `recover`, the fixes the footer offers (`TaskLauncher.recover`): one that did nothing would
    // offer a button whose create fails again with the same refusal. `fixer` and `pipeline` are the
    // agent's Fix (`FixSession`); without a pipeline a failure offers none.
    convenience init(project: Project, draft: ReviewDraft, context: CreationContext,
                     owningTask: @escaping (_ branch: String, _ checkouts: [Worktree]) -> TaskItem? = { _, _ in nil },
                     codeHost: CodeHost = .gitLab,
                     searchMergeRequests: @escaping @MainActor (String) async throws -> [MergeRequest],
                     tickets: ReviewTicketLookup = .none,
                     createReview: @escaping @MainActor (ReviewDraft) async throws -> Void,
                     recover: @escaping @MainActor (CreationFailure.Recovery) async throws -> Void,
                     fixer: @escaping @MainActor () -> FixerResolution = { .off }, pipeline: FixPipeline? = nil,
                     fixLanded: @escaping @MainActor (FixLanding, FixerAgent) -> Void = { _, _ in },
                     backupKept: @escaping @MainActor (FixLanding) -> Void = { _ in }) {
        self.init(kind: ReviewCreation(codeHost: codeHost, findOwner: owningTask, fix: recover, tickets: tickets), project: project, draft: draft, context: context,
                  search: searchMergeRequests, submit: createReview,
                  fixer: fixer, pipeline: pipeline, fixLanded: fixLanded, backupKept: backupKept)
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
    static func searcher(gitLab: GitLabConfig?, gitHub: GitHubConfig? = nil, remote: RemoteInfo, session: URLSession = .shared) -> @MainActor (String) async throws -> [MergeRequest] {
        let source = Result(catching: { () throws(MergeRequestSearch.Unavailable) -> any MergeRequestSearching in
            try MergeRequestSearch.source(for: remote, gitLab: gitLab, gitHub: gitHub, session: session)
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
        kind.ticketLookupNote = nil
        draft.apply(mr: mr)
        lookUpTicket(of: mr)
    }

    /// The sheet's clear action on a picked request.
    func clearPick() {
        kind.pickRefusal = nil
        kind.ticketLookupNote = nil
        kind.lookupTask?.cancel()
        draft.apply(mr: nil)
    }

    // -- the ticket field ----------------------------------------------------------------------

    var ticketQuery: String { kind.ticketSearch.query }
    var ticketResults: [JiraTicket] { kind.ticketSearch.results }
    var ticketSearchError: String? { kind.ticketSearch.error }
    var ticketLookupNote: String? { kind.ticketLookupNote }
    var requestListOffers: Int { kind.requestListOffers }

    /// As New Task's ticket field says what it searches.
    var ticketPlaceholder: String {
        TaskCreationModel.ticketPlaceholder(jiraProjects: kind.tickets.jiraProjects, jiraConnected: kind.tickets.jiraConnected,
                                            gitLabIssues: kind.ticketSearch.results.contains { $0.issueNumber != nil })
    }

    func setTicketQuery(_ text: String) { kind.ticketSearch.type(text) }

    func reopenTicketSearch() { setTicketQuery("") }

    /// As `search(text:debounce:)`: a stale answer is dropped, a failure clears the list, and one
    /// source failing beside another's rows shows both.
    func searchTickets(text: String, debounce: Bool = false) async { await kind.ticketSearch.search(text, debounce: debounce) }

    /// A ticket picked by hand, then its merge requests looked up in this repository: one is picked,
    /// several open the merge request list on them, none says so and starts the branch search from
    /// the key. A merge request picked by hand stays.
    func pickTicket(_ ticket: JiraTicket) {
        kind.ticketSearch.cancel()
        kind.ticketSearch.error = nil
        kind.ticketLookupNote = nil
        draft.apply(ticket: ticket)
        guard draft.mr == nil || draft.mrFoundFrom != nil else { return }
        let lookup = kind.tickets
        startLookup { [weak self] in
            let found = try await lookup.requests(ticket)
            guard let self, !Task.isCancelled, self.draft.ticket == ticket else { return }
            self.apply(found, for: ticket)
        }
    }

    func clearTicket() {
        kind.lookupTask?.cancel()
        kind.ticketLookupNote = nil
        draft.apply(ticket: nil)
    }

    private func apply(_ found: TicketMergeRequests.Found, for ticket: JiraTicket) {
        let usable = found.requests.filter { $0.forkHead == nil }
        if usable.count == 1, found.complete, let only = usable.first {
            draft.found(mr: only, from: ticket.key)
            return
        }
        if !usable.isEmpty {
            let noun = codeHost.reviewNoun
            kind.ticketLookupNote = usable.count == 1
                ? "1 open \(noun) mentions \(ticket.key)."
                : "\(usable.count) open \(noun)s mention \(ticket.key)."
            cancelSearch()
            results = usable
            kind.requestListOffers += 1
            return
        }
        kind.ticketLookupNote = found.complete
            ? "No open \(codeHost.reviewNoun) for \(ticket.key) in \(kind.tickets.repository)."
            : "None of the \(TicketMergeRequests.pages * 100) most recent open \(codeHost.reviewNoun)s in \(kind.tickets.repository) mention \(ticket.key)."
        if draft.branch.isEmpty { branchQuery = ticket.issueNumber.map { "\($0)-" } ?? ticket.key }
    }

    /// The merge request's ticket, read off it, unless one was picked by hand.
    private func lookUpTicket(of mr: MergeRequest) {
        guard draft.ticket == nil || draft.ticketFoundFrom != nil else { return }
        let lookup = kind.tickets
        startLookup { [weak self] in
            let ticket = try await lookup.ticket(mr)
            guard let self, !Task.isCancelled, self.draft.mr == mr, let ticket else { return }
            self.draft.found(ticket: ticket, from: mr.reference)
        }
    }

    /// One lookup at a time: a newer pick cancels the one before. A lookup that fails says nothing
    /// worse than not filling the field, which stays the person's to pick.
    private func startLookup(_ work: @escaping @MainActor () async throws -> Void) {
        kind.lookupTask?.cancel()
        kind.lookupTask = Task { @MainActor in
            await Log.network.attempt("Looking up the review’s ticket or merge request", level: .info) { try await work() }
        }
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
