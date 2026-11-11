import Foundation

/// Opens, watches and merges a task's merge request (GitLab) or pull request (GitHub), and involves
/// people on it: the only writes AiTerm makes to a code host, and only for an operator's `finish_task`
/// (spec §6) and its Review slice's tools (spec §5). Bound to one repository when it is made
/// (`MergeRequestPublisher.publisher(for:gitLab:gitHub:session:)`).
public protocol MergeRequestPublishing: Sendable {
    /// The repository it is bound to, as its host and path (`github.com/octocat/hello`, `git.example.net/web/acme-web`):
    /// kept on a publication when its request is opened, and compared before any later write to it.
    var repository: String { get }
    /// Whether the host protects `branch`; throws when it cannot say. Asked before every push (spec §3).
    func protection(of branch: String) async throws -> BranchProtection
    /// The open request from `source`, if there is one.
    func existingRequest(from source: String) async throws -> MergeRequest?
    func createRequest(from source: String, into target: String, title: String, description: String, draft: Bool) async throws -> MergeRequest
    func readiness(of number: Int) async throws -> MergeReadiness
    /// What the host says of `request` now: draft, pipeline, mergeability, approvals and head (`MergeRequestState`). Read only.
    func state(of request: MergeRequest) async throws -> MergeRequestState
    /// `.merged` when it merged, `.blocked` when the host refused; throws only when it could not be asked.
    func merge(_ number: Int, at sha: String) async throws -> MergeReadiness
    func retarget(_ number: Int, to target: String) async throws
    /// Changes its title, description and assignee as `edit` gives them, each nil one left as it is; the assignee replaces
    /// any it has. `beforeWrite` runs after the reads, with the request as the host has it now, right before the write, and
    /// its error stops it. A GitLab draft stays one whatever title is given. Safe to repeat.
    func updateRequest(_ number: Int, _ edit: RequestContent, beforeWrite: @Sendable (MergeRequest) async throws -> Void) async throws

    // The Review slice (spec §5): involving people on the request. Each is safe to repeat.
    /// Takes the request out of draft; one that is not a draft is left as it is. `beforeWrite` runs after the reads
    /// and right before the write, and its error stops the write.
    func markReady(_ number: Int, beforeWrite: @Sendable () async throws -> Void) async throws
    /// Asks `usernames` to review it, besides anyone asked already; `beforeWrite` as for `markReady`.
    func assignReviewers(_ number: Int, usernames: [String], beforeWrite: @Sendable () async throws -> Void) async throws
    /// Its review threads, oldest first: a plain comment or a system note is none.
    func threads(of number: Int) async throws -> [ReviewThread]
    /// A reply in the thread `thread`, as the token's user.
    func reply(_ number: Int, thread: String, body: String) async throws
    /// The thread `thread` whole: its file and line, and all its notes. Read only.
    func threadDetail(_ number: Int, thread: String) async throws -> ReviewThreadDetail
    /// Resolves the thread `thread`; resolving one resolved already changes nothing.
    func resolve(_ number: Int, thread: String) async throws
    /// Reruns what failed of the pipeline on its head, for `retry_pipeline`: GitLab's head pipeline, GitHub's latest Actions
    /// run of each workflow on the head. Reads the request and its pipeline first; only when something failed is
    /// `beforeWrite` run, with the request as read, right before each write, and its error stops it. Nothing failed:
    /// `.notFailed`, and nothing is written.
    func retryPipeline(_ number: Int, beforeWrite: @Sendable (MergeRequest) async throws -> Void) async throws -> PipelineRetry
    /// The people on the host who match `query`, by username or name, who may review here.
    func findUsers(_ query: String) async throws -> [HostUser]
    /// The usernames that approved it as it stands.
    func approvals(of number: Int) async throws -> [String]
    /// The username the token acts as: whose notes are AiTerm's own.
    func currentUser() async throws -> String
}

/// What a request says and who it is assigned to, as the Operator gives them (`finish_task` for the request it opens,
/// `update_request` after): each nil one is AiTerm's own on opening, and left as it is on an edit.
public struct RequestContent: Codable, Equatable, Sendable {
    public var title: String?
    public var description: String?
    /// A username on the request's host.
    public var assignee: String?
    public init(title: String? = nil, description: String? = nil, assignee: String? = nil) {
        self.title = title; self.description = description; self.assignee = assignee
    }
    public var isEmpty: Bool { title == nil && description == nil && assignee == nil }
}

/// What `retryPipeline` came to, in the host's own few words.
public enum PipelineRetry: Equatable, Sendable {
    /// Rerun: what (`pipeline 5501`, `the failed jobs of CI`).
    case retried(String)
    /// Nothing failed to rerun, and why (`its pipeline is running`).
    case notFailed(String)
}

extension MergeRequestPublishing {
    public func markReady(_ number: Int) async throws { try await markReady(number, beforeWrite: {}) }
    public func assignReviewers(_ number: Int, usernames: [String]) async throws {
        try await assignReviewers(number, usernames: usernames, beforeWrite: {})
    }
}

/// One connected repository: search, bounded badge reads and complete publication reads share its binding.
public protocol HostRepository: MergeRequestPublishing, MergeRequestSearching {
    /// The bounded, lenient thread counts shown on a request's badge.
    func reviewThreads(of number: Int) async throws -> ReviewThreads
    /// The repository's open requests, most recently updated first, up to `pages` pages of 100,
    /// and whether that was all of them: what a ticket's requests are looked for in.
    func openRequests(pages: Int) async throws -> (requests: [MergeRequest], complete: Bool)
    /// The open requests that close or mention issue `number` of this repository; none where the
    /// host's issues are not tickets (GitHub).
    func openRequests(closingIssue number: Int) async throws -> [MergeRequest]
}

public enum MergeRequestPublisher {
    /// The publisher for `remote`'s requests, with the connection Settings saved for its host.
    ///
    /// `remote` must be the repository the push goes to: `origin`'s fetch URL, which a push has
    /// already checked is its only push URL's host and path. `Repository.remoteUrl()` can name
    /// another remote (the branch's upstream), so it is not what to pass. A remote on a host that is
    /// not the configured GitLab or GitHub is `Unavailable`, never guessed at.
    public static func publisher(for remote: RemoteInfo, gitLab: GitLabConfig?, gitHub: GitHubConfig?,
                                 session: URLSession = .shared) throws(MergeRequestSearch.Unavailable) -> any MergeRequestPublishing {
        try MergeRequestSearch.source(for: remote, gitLab: gitLab, gitHub: gitHub, session: session)
    }
}
