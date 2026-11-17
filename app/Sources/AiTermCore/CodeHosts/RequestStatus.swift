import Foundation

/// What one status read of a request says: every fact comes from one fetch of the request, and every list that
/// depends on a commit was asked for the head that fetch named. Approvals are their own listing, read beside it.
public struct RequestStatus: Equatable, Sendable {
    /// The request as that fetch describes it: its state word, draft flag, url, branches, description and reviewers.
    public var request: MergeRequest
    /// The head commit that fetch names; GitLab may send none.
    public var head: String?
    /// Whether the host would merge it now, decided from that fetch by the host's rule
    /// (`MergeReadiness.gitHub` or `MergeReadiness.gitLab`).
    public var readiness: MergeReadiness
    /// The usernames that approved it.
    public var approvedBy: [String]
    /// Its checks as one word: on GitHub `success`, `failure` or `pending` (nil when there are none or they could not
    /// be listed whole), on GitLab the head pipeline's status as GitLab says it (nil when it has no pipeline).
    public var pipeline: String?

    public init(request: MergeRequest, head: String?, readiness: MergeReadiness, approvedBy: [String], pipeline: String?) {
        self.request = request; self.head = head; self.readiness = readiness; self.approvedBy = approvedBy; self.pipeline = pipeline
    }
}
