#if DEBUG
import Foundation
import Synchronization
import Testing

/// A one-shot rendezvous. Cancellation of the work under test does not release it: a stale
/// response can be delivered deliberately after cancellation. A missing signal fails at a deadline.
final class TestLatch: Sendable {
    private struct State {
        var open = false
        var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    }
    private let state = Mutex(State())

    func signal() {
        let waiting = state.withLock { state in
            state.open = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiting { waiter.resume(returning: true) }
    }

    func wait(sourceLocation: SourceLocation = #_sourceLocation) async {
        let id = UUID()
        var timer: Task<Void, Never>?
        let signaled = await withCheckedContinuation { continuation in
            let open = state.withLock { state in
                guard !state.open else { return true }
                state.waiters[id] = continuation
                return false
            }
            if open {
                continuation.resume(returning: true)
            } else {
                timer = Task {
                    do { try await Task.sleep(for: .seconds(TestDeadline.seconds)) }
                    catch { return }
                    state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(returning: false)
                }
            }
        }
        timer?.cancel()
        if !signaled { Issue.record("Timed out waiting for the latch", sourceLocation: sourceLocation) }
    }
}
#endif
