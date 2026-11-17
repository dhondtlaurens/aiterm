import Foundation

/// The reads the app makes of one request, plus merge, bound to one repository when it is made.
public protocol MergeRequestPublishing: Sendable {
    /// Whether the host protects `branch`; throws when it cannot say. Asked before a worker pushes.
    func protection(of branch: String) async throws -> BranchProtection
    /// The open request from `source`, if there is one.
    func existingRequest(from source: String) async throws -> MergeRequest?
    func readiness(of number: Int) async throws -> MergeReadiness
    /// Its pipeline, approvals and head as the host reports them now.
    func state(of request: MergeRequest) async throws -> MergeRequestState
    /// `.merged` when it merged, `.blocked` when the host refused; throws only when it could not be asked.
    func merge(_ number: Int, at sha: String) async throws -> MergeReadiness
    /// Its review threads, oldest first: a plain comment or a system note is none.
    func threads(of number: Int) async throws -> [ReviewThread]
    /// The usernames that approved it as it stands.
    func approvals(of number: Int) async throws -> [String]
    /// The username the token acts as: whose notes are AiTerm's own.
    func currentUser() async throws -> String
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
