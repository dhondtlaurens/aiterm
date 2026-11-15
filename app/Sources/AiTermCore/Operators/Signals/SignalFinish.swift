import Foundation

public struct SignalFinish: Codable, Equatable, Sendable {
    public enum Then: Codable, Hashable, Sendable, RawRepresentable, CaseIterable {
        case keep, archive, remove
        case unknown(String)
        public static let allCases: [Self] = [.keep, .archive, .remove]
        public init?(rawValue: String) {
            switch rawValue {
            case "keep": self = .keep
            case "archive": self = .archive
            case "remove": self = .remove
            default: self = .unknown(rawValue)
            }
        }
        public var rawValue: String {
            switch self {
            case .keep: "keep"
            case .archive: "archive"
            case .remove: "remove"
            case .unknown(let value): value
            }
        }
        public init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self))! }
        public func encode(to encoder: Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
    }
    public var doneWhen: DoneWhen
    public var then: Then
    public var mergesWhenReady: Bool
    public var deletesMergedBranch: Bool
    public init(doneWhen: DoneWhen, then: Then = .keep, mergesWhenReady: Bool = false, deletesMergedBranch: Bool = false) {
        self.doneWhen = doneWhen; self.then = then; self.mergesWhenReady = mergesWhenReady; self.deletesMergedBranch = deletesMergedBranch
    }
    public static func choices(for source: SignalSource) -> [DoneWhen] {
        guard source.isSupported else { return [] }
        switch source {
        case .jira: return [.operatorJudges, .hasReviewer, .approved, .threadsResolved, .merged, .ticketStatus("")]
        case .gitLab(let request), .gitHub(let request):
            return request.event == .reviewRequested ? [.myReviewPosted, .mergedOrClosed, .operatorJudges]
                : [.threadsResolved, .approved, .merged, .operatorJudges]
        case .unknown: return []
        }
    }
    public func isValid(for source: SignalSource) -> Bool {
        guard Self.Then.allCases.contains(then) else { return false }
        let allowed = Self.choices(for: source).contains { candidate in
            if case .ticketStatus = candidate, case .ticketStatus(let status) = doneWhen { return !status.isEmpty }
            return candidate == doneWhen
        }
        guard allowed else { return false }
        if deletesMergedBranch && then != .remove { return false }
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
