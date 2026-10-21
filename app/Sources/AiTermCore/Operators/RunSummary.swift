import Foundation

/// What the Summary tab says about a broadcast, read from the run's own fields: nothing yet while it
/// works, the wait while the Operator writes, the text once written, and why there is none when there never
/// will be one.
public enum RunSummary: Equatable, Sendable {
    /// The broadcast is still working.
    case notYet
    /// The plan is done and the Operator has not written it yet.
    case writing
    case written(text: String, at: Date)
    /// The plan was done, and the broadcast ended or AiTerm gave up waiting before a summary came.
    case notComing
    /// The broadcast ended before the plan was done, and the Operator wrote nothing.
    case endedEarly

    public init(_ run: OperatorRun) {
        if !run.hasEnded, run.completedAt == nil { self = .notYet }
        else if let text = run.summary { self = .written(text: text, at: run.summaryAt ?? run.completedAt ?? run.createdAt) }
        else if run.completedAt == nil { self = .endedEarly }
        else if run.summaryGivenUp || run.hasEnded { self = .notComing }
        else { self = .writing }
    }

    /// Nothing more will change: a summary is written, or none is coming.
    public var isSettled: Bool {
        switch self {
        case .written, .notComing: return true
        case .notYet, .writing, .endedEarly: return false
        }
    }
}
