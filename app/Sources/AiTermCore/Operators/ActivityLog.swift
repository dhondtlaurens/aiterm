import Foundation

/// One Operator tool call as the Activity tab shows it: when it came, what it asked, how it went and the
/// plain-words line for it.
public struct ActivityEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        /// The call went through.
        case ok
        /// AiTerm refused it, with a reason the Operator could act on.
        case refused
        /// It went wrong on AiTerm's side.
        case failed
    }

    public var id: UUID
    public var at: Date
    public var tool: String
    /// The task the call was about.
    public var task: UUID?
    public var arguments: JSONValue
    public var outcome: Outcome
    /// What AiTerm answered, trimmed to `resultLimit`.
    public var result: String
    public var line: String
    /// Why it went the way it did, for the ones that carry a reason (`ActivityLine.reason`).
    public var reason: String?

    /// The most of an answer a line of the log keeps.
    public static let resultLimit = 4096

    public init(id: UUID = UUID(), at: Date, tool: String, task: UUID?, arguments: JSONValue,
                outcome: Outcome, result: String, line: String, reason: String?) {
        self.id = id; self.at = at; self.tool = tool; self.task = task
        self.arguments = arguments; self.outcome = outcome; self.line = line; self.reason = reason
        self.result = String(result.prefix(Self.resultLimit))
    }
}

/// The Operator's `activity.jsonl`: one JSON line per Operator tool call, oldest first, written as each call is
/// made. Tests inspect the recorded calls with their own reader.
public enum ActivityLog {
    public static let file = "activity.jsonl"

    /// Adds `entry` as the last line of the Operator's log, creating the file with the first.
    public static func append(_ entry: ActivityEntry, folder: URL) throws {
        try JSONLines.append(entry, to: folder.appendingPathComponent(file))
    }
}
