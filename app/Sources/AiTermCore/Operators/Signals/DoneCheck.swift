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
        public init() {}
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
