import Foundation

public enum DoneCheck {
    public enum Result: Equatable, Sendable { case reached, waiting, unknown }
    public struct Facts: Equatable, Sendable {
        public var hostReadComplete = false
        public var ticketReadComplete = false
        public var operatorJudged = false
        public var hasReviewer = false
        public var approved = false
        public var threadsResolved = false
        public var merged = false
        public var closed = false
        public var reviewPostedAt: Date?
        public var ticketStatus: String?
        /// The request's reviewers, as its host names them; nil when the read did not carry them.
        public var reviewers: [String]?
        /// How many of its review threads are open; nil when this read did not ask for them.
        public var openThreads: Int?
        public init() {}
        /// What the sidebar says a waiting task waits on, from this read; nil when it carried neither.
        public var waitingOn: SignalWaitFacts? {
            reviewers == nil && openThreads == nil ? nil : SignalWaitFacts(reviewers: reviewers, openThreads: openThreads)
        }
    }
    public static func evaluate(_ condition: DoneWhen, facts: Facts, stageStartedAt: Date) -> Result {
        if condition == .operatorJudges { return facts.operatorJudged ? .reached : .waiting }
        if case .ticketStatus(let status) = condition {
            guard facts.ticketReadComplete else { return .unknown }
            return facts.ticketStatus == status ? .reached : .waiting
        }
        guard facts.hostReadComplete else { return .unknown }
        let reached: Bool
        switch condition {
        case .hasReviewer: reached = facts.hasReviewer
        case .approved: reached = facts.approved
        case .threadsResolved: reached = facts.threadsResolved
        case .merged: reached = facts.merged
        case .mergedOrClosed: reached = facts.merged || facts.closed
        case .myReviewPosted: reached = facts.reviewPostedAt.map { $0 >= stageStartedAt } ?? false
        case .unknown: return .unknown
        case .operatorJudges, .ticketStatus: return .unknown
        }
        return reached ? .reached : .waiting
    }
}

/// What a task's done check last read of the people and threads it waits on, kept on the task (`SignalTask.waitingOn`)
/// so its line can say whom or what it waits for (`OperatorLine.waiting`). Never asked of the host for the line alone:
/// the done check's own reads fill it.
public struct SignalWaitFacts: Codable, Equatable, Sendable {
    /// What a merge still lacks, in `MergeBlocker`'s words, once the done condition is met and only merge when ready
    /// holds the task; nil while the condition itself is still awaited, or the stage does not merge.
    public enum MergeBlocker: String, Codable, Sendable {
        case approval, checks, threads, push
        /// The host would not merge it for a reason none of the others names: conflicts, a draft, its own rules.
        case host
    }
    public var reviewers: [String]?
    public var openThreads: Int?
    public var mergeBlockers: [MergeBlocker]?
    public init(reviewers: [String]? = nil, openThreads: Int? = nil, mergeBlockers: [MergeBlocker]? = nil) {
        self.reviewers = reviewers; self.openThreads = openThreads; self.mergeBlockers = mergeBlockers
    }
    public var isEmpty: Bool { reviewers == nil && openThreads == nil && mergeBlockers == nil }
}
