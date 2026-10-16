import Foundation

/// Opens, watches and merges a task's merge request (GitLab) or pull request (GitHub): the only
/// writes AiTerm makes to a code host, and only for an operator's `finish_task` (spec §6). Bound to
/// one repository when it is made (`MergeRequestPublisher.publisher(for:gitLab:gitHub:session:)`).
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
}
