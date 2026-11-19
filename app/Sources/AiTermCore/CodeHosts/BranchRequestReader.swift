import Foundation

/// The merge or pull request a task's branch has, read from the host its project's remote names.
public protocol BranchRequestReading: Sendable {
    /// The branch's open request, else its newest one if that merged. `nil` when it has neither, and
    /// when the project's host is not connected or its remote names nothing there to ask; a request
    /// that was asked and failed throws.
    func request(remoteUrl: String?, branch: String) async throws -> MergeRequestRef?
}

/// Reads with the connections Settings saved, on the repository `CodeHosts` binds from the
/// project's remote, so a remote on another GitLab host than the configured one is never asked.
/// A request closed without merging was given up and is not the branch's.
public struct BranchRequestReader: BranchRequestReading {
    let gitLab: GitLabConfig?, gitHub: GitHubConfig?, session: URLSession

    public init(gitLab: GitLabConfig?, gitHub: GitHubConfig?, session: URLSession = .shared) {
        self.gitLab = gitLab; self.gitHub = gitHub; self.session = session
    }

    public func request(remoteUrl: String?, branch: String) async throws -> MergeRequestRef? {
        guard let remoteUrl, !branch.isEmpty,
              let repository = try? CodeHosts.repository(for: ProviderDetector.detect(remoteUrl: remoteUrl),
                                                         gitLab: gitLab, gitHub: gitHub, session: session) else { return nil }
        guard let found = try await repository.request(forBranch: branch), Self.isTaken(state: found.state) else { return nil }
        return MergeRequestRef(iid: found.iid, title: found.title, url: found.url)
    }

    /// Open (GitLab's `opened`, GitHub's `open`) or merged.
    static func isTaken(state: String) -> Bool { ["opened", "open", "merged"].contains(state) }
}
