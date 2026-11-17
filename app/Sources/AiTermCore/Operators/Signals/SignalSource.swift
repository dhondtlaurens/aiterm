import Foundation

public enum SignalSource: KindTaggedEnum, Equatable, Sendable {
    case jira(JiraConditions)
    case gitLab(RequestConditions)
    case gitHub(RequestConditions)
    case unknown(JSONValue)

    static func savedCase(kind: String?, value: SavedEnumValue) throws -> Self? {
        switch kind {
        case "jira":
            return .jira(try value.decode(JiraConditions.self))
        case "gitLab":
            return .gitLab(try value.decode(RequestConditions.self))
        case "gitHub":
            return .gitHub(try value.decode(RequestConditions.self))
        default: return nil
        }
    }

    var savedCase: SavedEnumCase {
        get throws {
            switch self {
            case .jira(let value): return .known("jira", try JSONValue(encoding: value))
            case .gitLab(let value): return .known("gitLab", try JSONValue(encoding: value))
            case .gitHub(let value): return .known("gitHub", try JSONValue(encoding: value))
            case .unknown(let value): return .unknown(value)
            }
        }
    }
}

public extension SignalSource {
    var isSupported: Bool {
        switch self {
        case .jira: true
        case .gitLab(let value), .gitHub(let value): value.event == .reviewRequested || value.event == .myRequest
        case .unknown: false
        }
    }
}

public struct JiraConditions: Codable, Equatable, Sendable {
    public var labels: [String]
    public var inOpenSprints: Bool
    /// `me` compiles to currentUser(); every other value is quoted.
    public var assignee: String?
    public var statuses: [String]
    public var projects: [String]
    public var jql: String?
    public init(labels: [String] = [], inOpenSprints: Bool = false, assignee: String? = nil,
                statuses: [String] = [], projects: [String] = [], jql: String? = nil) {
        self.labels = labels; self.inOpenSprints = inOpenSprints; self.assignee = assignee
        self.statuses = statuses; self.projects = projects; self.jql = jql
    }
}

public struct RequestConditions: Codable, Equatable, Sendable {
    public enum Event: OpenStringEnum, Hashable, Sendable {
        case reviewRequested, myRequest
        case unknown(String)
        static let knownCases: [Self] = [.reviewRequested, .myRequest]
        var savedName: String {
            switch self {
            case .reviewRequested: "reviewRequested"
            case .myRequest: "myRequest"
            case .unknown(let value): value
            }
        }
    }
    public var event: Event
    public var waitingOnMyReply: Bool
    public var sentBackToMe: Bool
    /// Empty means every repository the account can read. Canonical remote locations otherwise.
    public var projects: [String]
    public init(event: Event, waitingOnMyReply: Bool = true, sentBackToMe: Bool = true, projects: [String] = []) {
        self.event = event; self.waitingOnMyReply = waitingOnMyReply; self.sentBackToMe = sentBackToMe; self.projects = projects
    }
}

public enum JQL {
    public static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    public static func compile(_ conditions: JiraConditions) -> String {
        if let manual = conditions.jql?.trimmingCharacters(in: .whitespacesAndNewlines), !manual.isEmpty { return manual }
        var parts: [String] = []
        func add(_ field: String, _ values: [String]) {
            if !values.isEmpty { parts.append("\(field) in (\(values.map(quoted).joined(separator: ", ")))") }
        }
        add("labels", conditions.labels)
        if conditions.inOpenSprints { parts.append("sprint in openSprints()") }
        if let assignee = conditions.assignee, !assignee.isEmpty {
            parts.append("assignee = " + (assignee == "me" ? "currentUser()" : quoted(assignee)))
        }
        add("status", conditions.statuses); add("project", conditions.projects)
        return parts.joined(separator: " AND ")
    }
}
