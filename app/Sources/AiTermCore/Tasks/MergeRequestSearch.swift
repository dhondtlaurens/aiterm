import Foundation

/// One repository's open merge requests (GitLab) or pull requests (GitHub), searched by text. The
/// repository is bound when it is made (``MergeRequestSearch/source(for:gitLab:gitHub:)``).
public protocol MergeRequestSearching: Sendable {
    func mergeRequests(search: String) async throws -> [MergeRequest]
}

/// Which host serves a project's merge requests, and the search for them.
public enum MergeRequestSearch {
    /// Why a project's merge requests cannot be searched with the connections there are.
    public enum Unavailable: Error, Equatable, Sendable {
        /// No connection to the host the project's requests are on.
        case notConnected(CodeHost)
        /// The remote names no repository (GitHub) or project (GitLab) on the host.
        case noRepositoryPath(CodeHost)
        /// The project's remote is not on the one GitLab host that is configured.
        case otherGitLabHost(remote: String?, configured: String?)
    }

    /// Whose requests a project lists, by its remote: GitHub's for a GitHub remote, GitLab's for
    /// everything else — including a self-hosted GitLab the detector could only call plain git.
    public static func host(for remote: RemoteInfo) -> CodeHost {
        remote.provider == .github ? .gitHub : .gitLab
    }

    /// The host and the project on it that `remote`'s requests are on, with that host's connection.
    /// One GitLab host is configured, and a project whose remote points elsewhere is refused rather
    /// than asked there, which would name another project. Search and publishing both ask this.
    ///
    /// `remote` is only as right as the URL it was read from. Publishing needs the repository a push
    /// goes to, which is `origin`'s fetch URL (a push refuses unless origin has one push URL at that
    /// host and path); `Repository.remoteUrl()` may name another remote, the branch's upstream.
    public enum Connection: Equatable, Sendable {
        case gitHub(GitHubConfig, repo: String), gitLab(GitLabConfig, project: String)
    }

    public static func connection(for remote: RemoteInfo, gitLab: GitLabConfig?, gitHub: GitHubConfig?) throws(Unavailable) -> Connection {
        switch host(for: remote) {
        case .gitHub:
            guard let gitHub else { throw .notConnected(.gitHub) }
            guard !remote.path.isEmpty else { throw .noRepositoryPath(.gitHub) }
            return .gitHub(gitHub, repo: remote.path)
        case .gitLab:
            guard let gitLab else { throw .notConnected(.gitLab) }
            let configured = gitLab.hostURL.host?.lowercased()
            guard let host = remote.host, host == configured else {
                throw .otherGitLabHost(remote: remote.host, configured: gitLab.hostURL.host)
            }
            guard !remote.path.isEmpty else { throw .noRepositoryPath(.gitLab) }
            return .gitLab(gitLab, project: remote.path)
        }
    }

    /// The search for `remote`'s requests on ``host(for:)``, with that host's connection.
    public static func source(for remote: RemoteInfo, gitLab: GitLabConfig?, gitHub: GitHubConfig?) throws(Unavailable) -> any MergeRequestSearching {
        switch try connection(for: remote, gitLab: gitLab, gitHub: gitHub) {
        case .gitHub(let config, let repo): return GitHubPullRequestSearch(client: GitHubClient(config: config), repo: repo)
        case .gitLab(let config, let project): return GitLabMergeRequestSearch(client: GitLabClient(config: config), project: project)
        }
    }
}

/// A GitHub repository's open pull requests.
struct GitHubPullRequestSearch: MergeRequestSearching {
    let client: GitHubClient, repo: String
    func mergeRequests(search: String) async throws -> [MergeRequest] { try await client.pullRequests(repo: repo, search: search) }
}

/// A GitLab project's open merge requests.
struct GitLabMergeRequestSearch: MergeRequestSearching {
    let client: GitLabClient, project: String
    func mergeRequests(search: String) async throws -> [MergeRequest] { try await client.mergeRequests(project: project, search: search) }
}
