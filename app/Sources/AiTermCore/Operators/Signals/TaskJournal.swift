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
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var bytes = try encoder.encode(entry); bytes.append(10)
        if !FileManager.default.fileExists(atPath: path.path) {
            try bytes.write(to: path, options: .atomic)
        } else {
            let file = try FileHandle(forUpdating: path); defer { try? file.close() }
            var end = try file.seekToEnd()
            if end > 0 {
                try file.seek(toOffset: end - 1)
                if try file.read(upToCount: 1) != Data([10]) {
                    // Only an incomplete trailing record is discarded. Complete corrupt lines
                    // remain a read failure, rather than silently rewriting journal history.
                    var boundary: UInt64?
                    while end > 0 && boundary == nil {
                        let start = end > 8192 ? end - 8192 : 0
                        try file.seek(toOffset: start)
                        let tail = try file.read(upToCount: Int(end - start)) ?? Data()
                        if let newline = tail.lastIndex(of: 10) { boundary = start + UInt64(newline) + 1 }
                        end = start
                    }
                    try file.truncate(atOffset: boundary ?? 0)
                }
            }
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
