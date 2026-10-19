import Foundation

/// Opens, watches and merges a task's merge request (GitLab) or pull request (GitHub), and involves
/// people on it: the only writes AiTerm makes to a code host, and only for an operator's `finish_task`
/// (spec §6) and its Review slice's tools (spec §5). Bound to one repository when it is made
/// (`MergeRequestPublisher.publisher(for:gitLab:gitHub:session:)`).
public protocol MergeRequestPublishing: Sendable {
    /// Whether the host protects `branch`; throws when it cannot say. Asked before every push (spec §3).
    func protection(of branch: String) async throws -> BranchProtection
    /// The open request from `source`, if there is one.
    func existingRequest(from source: String) async throws -> MergeRequest?
    func createRequest(from source: String, into target: String, title: String, description: String, draft: Bool) async throws -> MergeRequest
    func readiness(of number: Int) async throws -> MergeReadiness
    /// `.merged` when it merged, `.blocked` when the host refused; throws only when it could not be asked.
    func merge(_ number: Int, at sha: String) async throws -> MergeReadiness
    func retarget(_ number: Int, to target: String) async throws

    // The Review slice (spec §5): involving people on the request. Each is safe to repeat.
    /// Takes the request out of draft; one that is not a draft is left as it is.
    func markReady(_ number: Int) async throws
    /// Asks `usernames` to review it, besides anyone asked already.
    func assignReviewers(_ number: Int, usernames: [String]) async throws
    /// Its review threads, oldest first: a plain comment or a system note is none.
    func threads(of number: Int) async throws -> [ReviewThread]
    /// A reply in the thread `thread`, as the token's user.
    func reply(_ number: Int, thread: String, body: String) async throws
    /// The people on the host who match `query`, by username or name, who may review here.
    func findUsers(_ query: String) async throws -> [HostUser]
    /// The usernames that approved it as it stands.
    func approvals(of number: Int) async throws -> [String]
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
        switch try MergeRequestSearch.connection(for: remote, gitLab: gitLab, gitHub: gitHub) {
        case .gitHub(let config, let repo): return GitHubPublisher(client: GitHubClient(config: config, session: session), repo: repo)
        case .gitLab(let config, let project): return GitLabPublisher(client: GitLabClient(config: config, session: session), project: project)
        }
    }
}

struct GitHubPublisher: MergeRequestPublishing {
    let client: GitHubClient, repo: String
    func protection(of branch: String) async throws -> BranchProtection { try await client.branchProtection(repo: repo, branch: branch) }
    func existingRequest(from source: String) async throws -> MergeRequest? { try await client.openPullRequest(repo: repo, source: source) }
    func createRequest(from source: String, into target: String, title: String, description: String, draft: Bool) async throws -> MergeRequest {
        try await client.createPullRequest(repo: repo, source: source, target: target, title: title, body: description, draft: draft)
    }
    func readiness(of number: Int) async throws -> MergeReadiness { try await client.mergeReadiness(repo: repo, number: number) }
    func merge(_ number: Int, at sha: String) async throws -> MergeReadiness { try await client.merge(repo: repo, number: number, sha: sha) }
    func retarget(_ number: Int, to target: String) async throws { try await client.retarget(repo: repo, number: number, to: target) }
    func markReady(_ number: Int) async throws { try await client.markReady(repo: repo, number: number) }
    func assignReviewers(_ number: Int, usernames: [String]) async throws {
        try await client.requestReviewers(repo: repo, number: number, logins: usernames)
    }
    func threads(of number: Int) async throws -> [ReviewThread] { try await client.threads(repo: repo, number: number) }
    func reply(_ number: Int, thread: String, body: String) async throws { try await client.reply(repo: repo, thread: thread, body: body) }
    func findUsers(_ query: String) async throws -> [HostUser] { try await client.findUsers(repo: repo, query: query) }
    func approvals(of number: Int) async throws -> [String] { try await client.approvals(repo: repo, number: number) }
}

struct GitLabPublisher: MergeRequestPublishing {
    let client: GitLabClient, project: String
    func protection(of branch: String) async throws -> BranchProtection { try await client.branchProtection(project: project, branch: branch) }
    func existingRequest(from source: String) async throws -> MergeRequest? { try await client.openMergeRequest(project: project, source: source) }
    func createRequest(from source: String, into target: String, title: String, description: String, draft: Bool) async throws -> MergeRequest {
        try await client.createMergeRequest(project: project, source: source, target: target, title: title, description: description, draft: draft)
    }
    func readiness(of number: Int) async throws -> MergeReadiness { try await client.mergeReadiness(project: project, iid: number) }
    func merge(_ number: Int, at sha: String) async throws -> MergeReadiness { try await client.merge(project: project, iid: number, sha: sha) }
    func retarget(_ number: Int, to target: String) async throws { try await client.retarget(project: project, iid: number, to: target) }
    func markReady(_ number: Int) async throws { try await client.markReady(project: project, iid: number) }
    func assignReviewers(_ number: Int, usernames: [String]) async throws {
        try await client.assignReviewers(project: project, iid: number, usernames: usernames)
    }
    func threads(of number: Int) async throws -> [ReviewThread] { try await client.threads(project: project, iid: number) }
    func reply(_ number: Int, thread: String, body: String) async throws {
        try await client.reply(project: project, iid: number, discussion: thread, body: body)
    }
    func findUsers(_ query: String) async throws -> [HostUser] { try await client.findUsers(project: project, query: query) }
    func approvals(of number: Int) async throws -> [String] { try await client.approvals(project: project, iid: number) }
}
