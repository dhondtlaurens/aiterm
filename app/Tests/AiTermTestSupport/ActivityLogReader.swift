import Foundation
import AiTermCore

/// The activity log reader used only to inspect recorded calls in tests.
public enum ActivityLogReader {
    /// The entries from byte `offset` on, in file order, and the offset after the last complete line, to read
    /// from next time. A line that does not decode is skipped; a last line still missing its newline is
    /// left for the next read; a missing file has nothing.
    public static func read(folder: URL, from offset: UInt64 = 0) -> (entries: [ActivityEntry], end: UInt64) {
        let path = folder.appendingPathComponent(ActivityLog.file).path
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
