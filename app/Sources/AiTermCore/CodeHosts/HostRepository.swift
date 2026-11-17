import Foundation

/// The reads the app makes of one request, plus merge, bound to one repository when it is made.
public protocol HostRepository: Sendable {
    // Picker: New Review and New Task ticket lookup.
    func mergeRequests(search: String) async throws -> [MergeRequest]
    /// The repository's open requests, most recently updated first, up to `pages` pages of 100,
    /// and whether that was all of them: what a ticket's requests are looked for in.
    func openRequests(pages: Int) async throws -> (requests: [MergeRequest], complete: Bool)
    /// The open requests that close or mention issue `number`; GitHub answers none.
    func openRequests(closingIssue number: Int) async throws -> [MergeRequest]

    // Push guard: worker guard and merged-branch cleanup.
    func defaultBranch() async throws -> String
    /// Whether the host protects `branch`; throws when it cannot say. Asked before a worker pushes.
    func protection(of branch: String) async throws -> BranchProtection

    // Watch: the Operator's reads of a task's request.
    /// The request with this number, or nil when the host has no such number.
    func request(number: Int) async throws -> MergeRequest?
    /// The newest request for the branch, including a closed or merged one.
    func request(forBranch branch: String) async throws -> MergeRequest?
    /// The open request from `source`, if there is one.
    func existingRequest(from source: String) async throws -> MergeRequest?
    func readiness(of number: Int) async throws -> MergeReadiness
    /// Its pipeline, approvals and head as the host reports them now.
    func state(of request: MergeRequest) async throws -> MergeRequestState
    /// Its review threads, oldest first: a plain comment or a system note is none.
    func threads(of number: Int) async throws -> [ReviewThread]
    /// The usernames that approved it as it stands.
    func approvals(of number: Int) async throws -> [String]
    func reviewers(of number: Int) async throws -> [String]
    func myReviewPostedAt(of number: Int) async throws -> Date?

    // Effect: merge at the accepted commit, the only host write.
    /// `.merged` when it merged, `.blocked` when the host refused; throws only when it could not be asked.
    func merge(_ number: Int, at sha: String) async throws -> MergeReadiness
}
