import Foundation

/// How many of a merge or pull request's review threads are resolved, whether it merged and whether
/// anyone approves it, read from the host it is on.
public protocol ReviewThreadsReading: Sendable {
    /// `nil` when the request's host is not connected, or its address names no project there to
    /// ask; a request that was asked and failed throws.
    func threads(of mr: MergeRequestRef) async throws -> ReviewThreads?
}

/// Reads with the connections Settings saved: GitHub's for a pull request on github.com, GitLab's
/// for a merge request on the one GitLab host configured. A merge request on another GitLab is not
/// asked of this one, as `CodeHosts` refuses a remote on another host, since its project
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
        let connection: CodeHosts.Connection
        switch Self.target(of: mr.url, gitLab: gitLab) {
        case .gitHub(let repo)?:
            guard let gitHub else { return nil }
            connection = .gitHub(gitHub, repo: repo)
        case .gitLab(let project)?:
            guard let gitLab else { return nil }
            connection = .gitLab(gitLab, project: project)
        case nil:
            return nil
        }
        let repository = connection.repository(session: session)
        // Side by side: the threads, the request itself for its state, and who approves it. All three or none.
        async let threads = repository.threads(of: mr.iid)
        async let request = repository.request(number: mr.iid)
        async let approvers = repository.approvals(of: mr.iid)
        return ReviewThreads(resolutions: try await threads.map(\.resolved), merged: try await request?.state == "merged",
                             approved: !(try await approvers).isEmpty)
    }

    /// `https://github.com/<owner>/<repo>/pull/<n>`, or `<GitLab host>/<project>/-/merge_requests/<n>`
    /// on the configured host, compared as DNS does,
    /// its case and a trailing dot ignored, and its port unless it is the scheme's own.
    /// A GitLab sub-path (`https://example.com/gitlab`) is left out of the project.
    static func target(of webURL: String, gitLab: GitLabConfig?) -> Target? {
        guard let url = URL(string: webURL) else { return nil }
        switch CodeHost(webURL: webURL) {
        case .gitHub:
            let parts = url.pathComponents
            guard parts.count >= 5, parts[3] == "pull" else { return nil }
            return .gitHub(repo: "\(parts[1])/\(parts[2])")
        case .gitLab:
            guard let gitLab, gitLab.serves(url) else { return nil }
            var root = gitLab.hostURL.path
            while root.hasSuffix("/") { root.removeLast() }
            guard url.path.hasPrefix(root + "/") else { return nil }
            // Keep the slash in front of the project, so a path that starts at the marker names none.
            let path = String(url.path.dropFirst(root.count))
            guard let marker = path.range(of: "/-/merge_requests/"),
                  marker.lowerBound > path.startIndex else { return nil }
            let project = String(path[path.index(after: path.startIndex)..<marker.lowerBound])
            return project.isEmpty ? nil : .gitLab(project: project)
        }
    }
}
