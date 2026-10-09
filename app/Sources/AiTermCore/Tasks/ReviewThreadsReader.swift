import Foundation

/// How many of a merge or pull request's review threads are resolved, read from the host it is on.
public protocol ReviewThreadsReading: Sendable {
    /// `nil` when the request's host is not connected, or its address names no project there to
    /// ask; a request that was asked and failed throws.
    func threads(of mr: MergeRequestRef) async throws -> ReviewThreads?
}

/// Reads with the connections Settings saved: GitHub's for a pull request on github.com, GitLab's
/// for a merge request on the one GitLab host configured. A merge request on another GitLab is not
/// asked of this one — as `MergeRequestSearch` refuses a remote on another host — since its project
/// path would name another project there, read with this host's token.
///
/// Where a request lives is read from the web address it was stored with (`MergeRequestRef.url`),
/// which names the project the request belongs to, whatever the checkout's remote says: a review of
/// a fork's branch still asks the project the request was opened in.
public struct ReviewThreadsReader: ReviewThreadsReading {
    /// Which project a request's threads are asked of, and on which host.
    enum Target: Equatable {
        case gitHub(repo: String), gitLab(project: String)
    }

    let gitLab: GitLabConfig?, gitHub: GitHubConfig?, session: URLSession

    public init(gitLab: GitLabConfig?, gitHub: GitHubConfig?, session: URLSession = .shared) {
        self.gitLab = gitLab; self.gitHub = gitHub; self.session = session
    }

    public func threads(of mr: MergeRequestRef) async throws -> ReviewThreads? {
        switch Self.target(of: mr.url, gitLabHost: gitLab?.hostURL) {
        case .gitHub(let repo)?:
            guard let gitHub else { return nil }
            return try await GitHubClient(config: gitHub, session: session).reviewThreads(repo: repo, number: mr.iid)
        case .gitLab(let project)?:
            guard let gitLab else { return nil }
            return try await GitLabClient(config: gitLab, session: session).reviewThreads(project: project, iid: mr.iid)
        case nil:
            return nil
        }
    }

    /// `https://github.com/<owner>/<repo>/pull/<n>`, or `<GitLab host>/<project>/-/merge_requests/<n>`
    /// (`/merge_requests/` alone before GitLab 12.0) on the configured host — compared as DNS does,
    /// its case and a trailing dot ignored — with the sub-path a GitLab is served from
    /// (`https://example.com/gitlab`) left out of the project.
    static func target(of webURL: String, gitLabHost: URL?) -> Target? {
        guard let url = URL(string: webURL) else { return nil }
        switch CodeHost(webURL: webURL) {
        case .gitHub:
            let parts = url.pathComponents
            guard parts.count >= 5, parts[3] == "pull" else { return nil }
            return .gitHub(repo: "\(parts[1])/\(parts[2])")
        case .gitLab:
            guard let gitLabHost, let host = url.comparableHost, host == gitLabHost.comparableHost else { return nil }
            var root = gitLabHost.path
            while root.hasSuffix("/") { root.removeLast() }
            guard url.path.hasPrefix(root + "/") else { return nil }
            let path = String(url.path.dropFirst(root.count + 1))
            guard let marker = path.range(of: "/-/merge_requests/") ?? path.range(of: "/merge_requests/") else { return nil }
            let project = String(path[..<marker.lowerBound])
            return project.isEmpty ? nil : .gitLab(project: project)
        }
    }
}
