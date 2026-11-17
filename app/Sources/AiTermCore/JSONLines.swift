import Foundation

/// One complete JSON record per line, with ISO 8601 dates and crash-safe trailing-record repair.
public enum JSONLines {
    /// The first write is atomic; later appends discard only an incomplete trailing record.
    public static func append<Value: Encodable>(_ entry: Value, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var bytes = try encoder.encode(entry); bytes.append(10)
        if !FileManager.default.fileExists(atPath: file.path) {
            try bytes.write(to: file, options: .atomic)
        } else {
            let handle = try FileHandle(forUpdating: file); defer { try? handle.close() }
            var end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data([10]) {
                    // Only an incomplete trailing record is discarded. Complete corrupt lines
                    // remain a read failure, rather than silently rewriting history.
                    var boundary: UInt64?
                    while end > 0 && boundary == nil {
                        let start = end > 8192 ? end - 8192 : 0
                        try handle.seek(toOffset: start)
                        let tail = try handle.read(upToCount: Int(end - start)) ?? Data()
                        if let newline = tail.lastIndex(of: 10) { boundary = start + UInt64(newline) + 1 }
                        end = start
                    }
                    try handle.truncate(atOffset: boundary ?? 0)
                }
            }
            try handle.seekToEnd(); try handle.write(contentsOf: bytes)
        }
    }

    /// Missing files are empty; incomplete tails wait, and corrupt complete records throw.
    public static func read<Value: Decodable>(_ type: Value.Type, from file: URL) throws -> [Value] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let bytes = try Data(contentsOf: file)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        // A partial last append waits for completion; a corrupt complete record is a read failure.
        guard let end = bytes.lastIndex(of: 10) else { return [] }
        return try bytes[...end].split(separator: 10).map { try decoder.decode(Value.self, from: Data($0)) }
    }
}
