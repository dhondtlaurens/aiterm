import Foundation

public struct SignalFinish: Codable, Equatable, Sendable {
    public enum Then: String, Codable, Sendable, CaseIterable { case keep, archive, remove }
    public var doneWhen: DoneWhen
    public var then: Then
    public var mergesWhenReady: Bool
    public var deletesMergedBranch: Bool
    public init(doneWhen: DoneWhen, then: Then = .keep, mergesWhenReady: Bool = false, deletesMergedBranch: Bool = false) {
        self.doneWhen = doneWhen; self.then = then; self.mergesWhenReady = mergesWhenReady; self.deletesMergedBranch = deletesMergedBranch
    }
    public static func choices(for source: SignalSource) -> [DoneWhen] {
        switch source {
        case .jira: return [.operatorJudges, .hasReviewer, .approved, .threadsResolved, .merged, .ticketStatus("")]
        case .gitLab(let request), .gitHub(let request):
            return request.event == .reviewRequested ? [.myReviewPosted, .mergedOrClosed, .operatorJudges]
                : [.threadsResolved, .approved, .merged, .operatorJudges]
        case .unknown: return []
        }
    }
    public func isValid(for source: SignalSource) -> Bool {
        let allowed = Self.choices(for: source).contains { candidate in
            if case .ticketStatus = candidate, case .ticketStatus(let status) = doneWhen { return !status.isEmpty }
            return candidate == doneWhen
        }
        guard allowed else { return false }
        if deletesMergedBranch && (then != .remove || doneWhen != .merged) { return false }
        if mergesWhenReady {
            if doneWhen == .merged { return false }
            switch source {
            case .gitLab(let c), .gitHub(let c): if c.event == .reviewRequested { return false }
            case .jira: break
            case .unknown: return false
            }
        }
        return true
    }
}
