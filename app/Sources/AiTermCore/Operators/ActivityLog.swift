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
/// made and read by whoever shows it.
public enum ActivityLog {
    public static let file = "activity.jsonl"

    /// Adds `entry` as the last line of the Operator's log, creating the file with the first.
    public static func append(_ entry: ActivityEntry, folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(entry)
        data.append(0x0A)
        let path = folder.appendingPathComponent(file).path
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
            }
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// The entries from byte `offset` on, in file order, and the offset after the last complete line, to read
    /// from next time. A line that does not decode is skipped; a last line still missing its newline is
    /// left for the next read; a missing file has nothing.
    public static func read(folder: URL, from offset: UInt64 = 0) -> (entries: [ActivityEntry], end: UInt64) {
        let path = folder.appendingPathComponent(file).path
        guard let handle = FileHandle(forReadingAtPath: path) else { return ([], offset) }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(), !data.isEmpty,
              let lastNewline = data.lastIndex(of: 0x0A) else { return ([], offset) }
        let complete = data[data.startIndex...lastNewline]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = complete.split(separator: 0x0A).compactMap { try? decoder.decode(ActivityEntry.self, from: Data($0)) }
        return (entries, offset + UInt64(complete.count))
    }
}
