import Dispatch
import Testing
@testable import AiTermTestSupport

/// The queue the caller runs on, by name: a worker of Swift's cooperative pool is named for it, a
/// thread of one's own for none.
private func currentQueue() -> String { String(cString: __dispatch_queue_get_label(nil)) }

/// `.blocking` moves a suite's tests off the cooperative pool, where a test that waits on a process
/// holds a worker every other test's `await` needs.
@Suite(.blocking) struct BlockingTraitTests {
    @Test func aSynchronousTestRunsOffThePool() {
        #expect(!currentQueue().contains("cooperative"), "ran on \(currentQueue())")
    }

    @Test func anAsyncTestResumesOffThePool() async throws {
        try await Task.sleep(for: .milliseconds(1))
        #expect(!currentQueue().contains("cooperative"), "resumed on \(currentQueue())")
    }

    /// Callers a test starts side by side still run side by side: each waits for the other, which
    /// only returns if they are on threads of their own.
    @Test func childTasksRunSideBySide() async {
        let first = DispatchSemaphore(value: 0), second = DispatchSemaphore(value: 0)
        async let a: Bool = { first.signal(); return second.wait(timeout: .now() + 10) == .success }()
        async let b: Bool = { second.signal(); return first.wait(timeout: .now() + 10) == .success }()
        #expect(await [a, b] == [true, true])
    }
}

/// Without the trait a synchronous test runs on the pool: what makes the probe above mean something.
///
/// It leans on two things that are not this code's: libdispatch naming the pool's workers'
/// queues "…cooperative", and the runner calling a synchronous test on that pool, as it does in
/// parallel mode. If either changes, this fails first, and the probes above need another witness.
@Suite struct UnmarkedTestPlacementTests {
    @Test func aSynchronousTestRunsOnThePool() {
        #expect(currentQueue().contains("cooperative"), "ran on \(currentQueue())")
    }
}
