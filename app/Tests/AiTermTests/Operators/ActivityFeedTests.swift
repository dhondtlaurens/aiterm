import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

/// The Operator sheet's Activity as it follows the run's `activity.jsonl`: newest first, each refresh reading
/// only what was appended since the last, and starting over when the file went or was cut short.
@MainActor
struct ActivityFeedTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("activity-feed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func entry(_ n: Int) -> ActivityEntry {
        ActivityEntry(id: UUID(), at: Date(timeIntervalSince1970: 1_800_000_000 + Double(n)), tool: "mark_task", task: nil,
                      taskLabel: nil, arguments: ["n": .int(n)], outcome: .ok, result: "done \(n)", line: "Line \(n)", reason: nil)
    }

    @Test func anEmptyFolderHasNothing() async throws {
        let feed = ActivityFeed(runFolder: try folder())
        await feed.refresh()
        #expect(feed.entries == [])
        #expect(feed.offset == 0)
    }

    @Test func newestFirstAndOnlyTheNewBytes() async throws {
        let dir = try folder()
        let first = entry(1), second = entry(2), third = entry(3)
        try ActivityLog.append(first, runFolder: dir)
        try ActivityLog.append(second, runFolder: dir)
        let feed = ActivityFeed(runFolder: dir)
        await feed.refresh()
        #expect(feed.entries == [second, first])
        let afterTwo = feed.offset
        #expect(afterTwo > 0)

        try ActivityLog.append(third, runFolder: dir)
        await feed.refresh()
        #expect(feed.entries == [third, second, first])
        #expect(feed.offset > afterTwo, "read on from where it stopped")
        #expect(feed.offset == ActivityLog.read(runFolder: dir).end)

        await feed.refresh()
        #expect(feed.entries == [third, second, first], "nothing new, nothing added twice")
    }

    /// The run folder went (the broadcast was removed), or the log was cut shorter than what was read: start over.
    @Test func aFileGoneOrCutShortStartsOver() async throws {
        let dir = try folder()
        try ActivityLog.append(entry(1), runFolder: dir)
        try ActivityLog.append(entry(2), runFolder: dir)
        let feed = ActivityFeed(runFolder: dir)
        await feed.refresh()
        #expect(feed.entries.count == 2)

        let file = dir.appendingPathComponent(ActivityLog.file)
        try FileManager.default.removeItem(at: file)
        await feed.refresh()
        #expect(feed.entries == [] && feed.offset == 0)

        try ActivityLog.append(entry(1), runFolder: dir)
        try ActivityLog.append(entry(2), runFolder: dir)
        await feed.refresh()
        let shorter = entry(9)
        try FileManager.default.removeItem(at: file)
        try ActivityLog.append(shorter, runFolder: dir)
        await feed.refresh()
        #expect(feed.entries == [shorter], "read again from the start")
        #expect(feed.offset == ActivityLog.read(runFolder: dir).end)
    }
}
