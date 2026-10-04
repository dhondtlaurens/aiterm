import Foundation
import Synchronization
import Testing
@testable import AiTermCore

@Suite struct SerialThreadTests {
    /// One job at a time, in the order they came: a turn-on, a turn-off and a check never overlap.
    @Test func jobsRunOneAtATimeInOrder() async {
        let worker = SerialThread(name: "test.serial")
        let log = Mutex<[Int]>([])
        async let first: Void = worker.run { Thread.sleep(forTimeInterval: 0.05); log.withLock { $0.append(1) } }
        try? await Task.sleep(for: .milliseconds(10))
        async let second: Void = worker.run { log.withLock { $0.append(2) } }
        _ = await (first, second)
        #expect(log.withLock { $0 } == [1, 2])
    }

    /// `sync` waits behind what is already queued, then hands back its own answer.
    @Test func syncWaitsBehindQueuedWork() {
        let worker = SerialThread(name: "test.serial")
        let log = Mutex<[String]>([])
        worker.enqueue { Thread.sleep(forTimeInterval: 0.05); log.withLock { $0.append("queued") } }
        let answer = worker.sync { log.withLock { $0.append("sync") }; return 42 }
        #expect(answer == 42)
        #expect(log.withLock { $0 } == ["queued", "sync"])
    }

    /// The work runs on the worker's own thread, never on a Dispatch worker the test pool shares.
    @Test func workRunsOnItsOwnNamedThread() async {
        let worker = SerialThread(name: "test.serial.named")
        let name = await worker.run { Thread.current.name }
        #expect(name == "test.serial.named")
        let oneOff = await ThreadWork.run { Thread.current.name ?? "" }
        #expect(oneOff == "aiterm.blocking")
    }
}
