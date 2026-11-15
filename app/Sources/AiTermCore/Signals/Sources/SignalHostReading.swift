import Foundation

/// Extra read-only evidence used by signal finish conditions. Publication stays on the existing
/// repository binding; complete listings are required before a review can be called posted.
public protocol SignalHostReading: HostRepository {
    func defaultBranch() async throws -> String
    func signalReviewers(of number: Int) async throws -> [String]
    func mySignalReviewPostedAt(of number: Int) async throws -> Date?
}

extension MergeRequestSearch {
    public static func signalSource(for remote: RemoteInfo, gitLab: GitLabConfig?, gitHub: GitHubConfig?,
                                    session: URLSession = .shared) throws(Unavailable) -> any SignalHostReading {
        switch try connection(for: remote, gitLab: gitLab, gitHub: gitHub) {
        case .gitHub(let config, let repo): return GitHubClient(config: config, repo: repo, session: session)
        case .gitLab(let config, let project): return GitLabClient(config: config, project: project, session: session)
        }
    }
}
