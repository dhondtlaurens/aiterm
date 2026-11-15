import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct SignalJournalRecoveryTests {
    @Test(.blocking) func appendAfterAnInterruptedWriteKeepsTheCompleteRecords() async throws {
        try await BackgroundWork.run {
            let folder = try ScratchFolder.make("aiterm-signal-journal-")
            defer { try? FileManager.default.removeItem(at: folder) }
            let id = UUID(), at = Date(timeIntervalSince1970: 1_800_000_000)
            let first = TaskJournal.Entry(at: at, stage: 1, text: .ours("First decision."))
            let second = TaskJournal.Entry(at: at, stage: 1, text: .ours("Next decision."))
            try TaskJournal.append(first, task: id, folder: folder)
            let path = folder.appendingPathComponent(id.uuidString + ".jsonl")
            let file = try FileHandle(forWritingTo: path)
            try file.seekToEnd(); try file.write(contentsOf: Data("{\"incomplete\":".utf8)); try file.close()
            #expect(try TaskJournal.read(task: id, folder: folder) == [first])
            try TaskJournal.append(second, task: id, folder: folder)
            #expect(try TaskJournal.read(task: id, folder: folder) == [first, second])
        }
    }
}
