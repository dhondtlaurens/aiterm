import Foundation

/// Append-only durable records. Host text is always a distinct quoted value, never part of ours.
/// The owner calls this file adapter through BackgroundWork, retaining only a bounded tail in state.
public enum TaskJournal {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var at: Date
        public var stage: Int
        public var text: JournalText
        public init(id: UUID = UUID(), at: Date, stage: Int, text: JournalText) { self.id = id; self.at = at; self.stage = stage; self.text = text }
    }
    public static let stateLimit = 20
    public static func append(_ entry: Entry, task: UUID, folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent(task.uuidString + ".jsonl")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var bytes = try encoder.encode(entry); bytes.append(10)
        if !FileManager.default.fileExists(atPath: path.path) {
            try bytes.write(to: path, options: .atomic)
        } else {
            let file = try FileHandle(forWritingTo: path); defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: bytes)
        }
    }
    public static func read(task: UUID, folder: URL) throws -> [Entry] {
        let path = folder.appendingPathComponent(task.uuidString + ".jsonl")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let bytes = try Data(contentsOf: path)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        // A partial last append waits for completion; a corrupt complete record is a read failure.
        guard let end = bytes.lastIndex(of: 10) else { return [] }
        return try bytes[...end].split(separator: 10).map { try decoder.decode(Entry.self, from: Data($0)) }
    }
}
