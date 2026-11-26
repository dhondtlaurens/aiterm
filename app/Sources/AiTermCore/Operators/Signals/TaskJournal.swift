import Foundation

/// Append-only durable records. Host text is always a distinct quoted value, never part of ours.
/// The owner calls this file adapter through BackgroundWork, retaining only a bounded tail in state.
public enum TaskJournal {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var key: String?
        public var at: Date
        public var stage: Int
        public var text: JournalText
        public init(id: UUID = UUID(), at: Date, stage: Int, text: JournalText, key: String? = nil) {
            self.id = id; self.at = at; self.stage = stage; self.text = text; self.key = key
        }
    }
    public static let stateLimit = 20
    public static func append(_ entry: Entry, task: UUID, folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent(task.uuidString + ".jsonl")
        try JSONLines.append(entry, to: path)
    }
    public static func read(task: UUID, folder: URL) throws -> [Entry] {
        let path = folder.appendingPathComponent(task.uuidString + ".jsonl")
        return try JSONLines.read(Entry.self, from: path)
    }
}

public enum JournalText: KindTaggedEnum, Equatable, Sendable {
    case ours(String)
    case quoted(SignalQuote)

    static func savedCase(kind: String?, value: SavedEnumValue) throws -> Self? {
        switch kind {
        case "ours":
            return .ours(try value.decode(String.self))
        case "quoted":
            return .quoted(try value.decode(SignalQuote.self))
        default: return nil
        }
    }

    var savedCase: SavedEnumCase {
        get throws {
            switch self {
            case .ours(let value): return .known("ours", try JSONValue(encoding: value))
            case .quoted(let value): return .known("quoted", try JSONValue(encoding: value))
            }
        }
    }
}

public struct SignalQuote: Codable, Equatable, Sendable {
    public var source: String
    public var text: String
    public init(source: String, text: String) { self.source = source; self.text = text }
}
