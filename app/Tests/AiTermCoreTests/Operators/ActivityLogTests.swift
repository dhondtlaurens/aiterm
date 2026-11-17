import AiTermTestSupport
import Testing
import Foundation
@testable import AiTermCore

/// The activity log uses the shared JSON-lines rules and preserves call order.
@Suite struct ActivityLogTests {

    private func entry(_ n: Int = 0, tool: String = "note") -> ActivityEntry {
        ActivityEntry(id: UUID(), at: Date(timeIntervalSince1970: 1_800_000_000 + Double(n)), tool: tool, task: nil,
                      arguments: ["n": .int(n)], outcome: .ok, result: "done \(n)", line: "Line \(n)", reason: nil)
    }

    @Test func appendsAndReadsInOrder() throws {
        let dir = try ScratchFolder.make("activity-")
        let first = entry(1), second = entry(2, tool: "log_decision")
        try ActivityLog.append(first, folder: dir)
        try ActivityLog.append(second, folder: dir)
        #expect(try JSONLines.read(ActivityEntry.self, from: dir.appendingPathComponent(ActivityLog.file)) == [first, second])
    }

    @Test func appendRepairsAnInterruptedActivityLine() throws {
        let dir = try ScratchFolder.make("activity-")
        let first = entry(1), second = entry(2)
        try ActivityLog.append(first, folder: dir)
        let file = dir.appendingPathComponent(ActivityLog.file)
        var torn = try Data(contentsOf: file); torn.append(Data("{unfinished".utf8))
        try torn.write(to: file)
        try ActivityLog.append(second, folder: dir)
        #expect(try JSONLines.read(ActivityEntry.self, from: file) == [first, second])
    }

    @Test func fiveHundredAppends() throws {
        let dir = try ScratchFolder.make("activity-")
        let all = (0..<500).map { entry($0) }
        for entry in all { try ActivityLog.append(entry, folder: dir) }
        #expect(try JSONLines.read(ActivityEntry.self, from: dir.appendingPathComponent(ActivityLog.file)) == all)
    }

    @Test func aResultIsTrimmedToItsLimit() {
        let long = String(repeating: "x", count: ActivityEntry.resultLimit + 50)
        let made = ActivityEntry(id: UUID(), at: Date(), tool: "run_status", task: nil, arguments: .null,
                                 outcome: .ok, result: long, line: "", reason: nil)
        #expect(made.result.count == ActivityEntry.resultLimit)
    }
}
