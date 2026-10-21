import Foundation
import Observation
import AiTermCore

/// A broadcast's activity log as the Operator sheet's Activity lists it: the run folder's `activity.jsonl`
/// (`ActivityLog`), newest first. Each `refresh` reads only what was appended since the last, off the main
/// actor; the sheet's host calls it as the sheet opens and after each line the Operator's calls write
/// (`OperatorController.activityGeneration(of:)`). A file that went, or is shorter than what was read, is
/// read again from the start.
@MainActor @Observable
final class ActivityFeed {
    let runFolder: URL
    /// Newest first.
    private(set) var entries: [ActivityEntry] = []
    /// How far into the file has been read: the byte after its last complete line.
    @ObservationIgnored private(set) var offset: UInt64 = 0
    /// The read in flight, which the next waits for, so two never read the same bytes.
    @ObservationIgnored private var reading: Task<Void, Never>?

    init(runFolder: URL) { self.runFolder = runFolder }

    /// Reads what was appended since the last refresh, after any read still in flight.
    func refresh() async {
        let before = reading
        let read = Task {
            await before?.value
            await readOn()
        }
        reading = read
        await read.value
    }

    private func readOn() async {
        let folder = runFolder, from = offset
        let read = await BackgroundWork.run { Self.read(folder, from: from) }
        if read.restarted {
            offset = read.end
            entries = read.entries.reversed()
        } else if read.end != from {
            offset = read.end
            if !read.entries.isEmpty { entries = read.entries.reversed() + entries }
        }
    }

    /// The entries from `from` on, or from the start when the file is gone or shorter than `from`.
    private nonisolated static func read(_ folder: URL, from: UInt64) -> (entries: [ActivityEntry], end: UInt64, restarted: Bool) {
        let path = folder.appendingPathComponent(ActivityLog.file).path
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.uint64Value
        guard let size else { return ([], 0, from != 0) }
        let start = size < from ? 0 : from
        let read = ActivityLog.read(runFolder: folder, from: start)
        return (read.entries, read.end, start != from)
    }
}
