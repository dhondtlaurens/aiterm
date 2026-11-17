import Testing
import Foundation
import Synchronization
@testable import AiTermCore
@testable import AiTermTestSupport

final class RegularFileTests {
    let dir: String

    init() throws { dir = try GitFixture.folder("regular-file-") }
    deinit { try? FileManager.default.removeItem(atPath: dir) }

    @Test func anAnswerFileOverAMegabyteIsNoAnswer() throws {
        let file = dir + "/answer"
        try Data(repeating: 32, count: HeadlessRun.answerLimit + 1).write(to: URL(fileURLWithPath: file))
        #expect(RegularFile.read(file, limit: HeadlessRun.answerLimit) == nil)
    }

    /// A FIFO is rejected without waiting for a writer.
    @Test(.blocking) func anAnswerFileThatIsAFifoIsNoAnswerAndNeverWaitedOn() throws {
        let file = dir + "/answer"
        #expect(mkfifo(file, 0o644) == 0)
        let done = DispatchSemaphore(value: 0)
        let result = Mutex<RegularFile.Entry?>(.absent)
        Thread.detachNewThread {
            result.withLock { $0 = RegularFile.read(file, limit: HeadlessRun.answerLimit) }
            done.signal()
        }
        let finished = done.wait(timeout: .now() + 5) == .success
        if !finished {
            let writer = open(file, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
            done.wait()
        }
        #expect(finished)
        #expect(result.withLock { $0 } == nil)
    }

    @Test func aSymlinkIsNotRead() throws {
        let target = dir + "/target", file = dir + "/answer"
        try Data("answer".utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: target)
        #expect(RegularFile.read(file, limit: HeadlessRun.answerLimit) == nil)
    }

    @Test func anAbsentFileIsAbsent() {
        #expect(RegularFile.read(dir + "/answer", limit: HeadlessRun.answerLimit) == .absent)
    }
}
