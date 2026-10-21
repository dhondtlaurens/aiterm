import Testing
import Foundation
@testable import AiTermCore

/// The activity log's file: one JSON line per Operator tool call, appended as they happen and read back in
/// order from wherever the reader stopped.
@Suite struct ActivityLogTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(_ n: Int = 0, tool: String = "mark_task") -> ActivityEntry {
        ActivityEntry(id: UUID(), at: Date(timeIntervalSince1970: 1_800_000_000 + Double(n)), tool: tool, task: nil,
                      taskLabel: nil, arguments: ["n": .int(n)], outcome: .ok, result: "done \(n)", line: "Line \(n)", reason: nil)
    }

    private func write(_ text: String, in folder: URL) throws {
        let path = folder.appendingPathComponent(ActivityLog.file).path
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    private func line(_ entry: ActivityEntry) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(entry), as: UTF8.self)
    }

    @Test func appendsAndReadsInOrder() throws {
        let dir = try folder()
        let first = entry(1), second = entry(2, tool: "log_decision")
        try ActivityLog.append(first, runFolder: dir)
        try ActivityLog.append(second, runFolder: dir)
        let read = ActivityLog.read(runFolder: dir)
        #expect(read.entries == [first, second])
        #expect(read.end == UInt64(try Data(contentsOf: dir.appendingPathComponent(ActivityLog.file)).count))
    }

    @Test func aMalformedLineIsSkipped() throws {
        let dir = try folder()
        let first = entry(1), second = entry(2)
        try write(try line(first) + "\n{\"x\":\n" + (try line(second)) + "\n", in: dir)
        #expect(ActivityLog.read(runFolder: dir).entries == [first, second])
    }

    @Test func aTornLastLineWaits() throws {
        let dir = try folder()
        let first = entry(1), second = entry(2)
        let firstLine = try line(first) + "\n"
        let secondLine = try line(second)
        let half = secondLine.index(secondLine.startIndex, offsetBy: secondLine.count / 2)
        try write(firstLine + String(secondLine[..<half]), in: dir)
        let torn = ActivityLog.read(runFolder: dir)
        #expect(torn.entries == [first])
        #expect(torn.end == UInt64(firstLine.utf8.count))
        try write(String(secondLine[half...]) + "\n", in: dir)
        let next = ActivityLog.read(runFolder: dir, from: torn.end)
        #expect(next.entries == [second])
    }

    @Test func aMissingFileIsEmpty() throws {
        let read = ActivityLog.read(runFolder: try folder())
        #expect(read.entries.isEmpty)
        #expect(read.end == 0)
    }

    @Test func fiveHundredAppends() throws {
        let dir = try folder()
        let all = (0..<500).map { entry($0) }
        for entry in all { try ActivityLog.append(entry, runFolder: dir) }
        #expect(ActivityLog.read(runFolder: dir).entries == all)
    }

    @Test func aResultIsTrimmedToItsLimit() {
        let long = String(repeating: "x", count: ActivityEntry.resultLimit + 50)
        let made = ActivityEntry(id: UUID(), at: Date(), tool: "run_status", task: nil, taskLabel: nil, arguments: .null,
                                 outcome: .ok, result: long, line: "", reason: nil)
        #expect(made.result.count == ActivityEntry.resultLimit)
        #expect(made.isRead)
    }
}
