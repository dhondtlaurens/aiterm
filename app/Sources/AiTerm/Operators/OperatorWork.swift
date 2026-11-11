import Foundation

/// The work the Operator's owners start and that runs to an end: a turn or transcript read, a prompt probe, a branch or
/// review pass, a wake line's coalescing and delivery, a start, a relaunch, a tab asked for again, a registration, a
/// summary's wait, the notes Pause and Resume type. Each owner starts it here (`start`), so a test waits for all of it
/// with one await (the tests' `settled`, until nothing is `running`) instead of reaching for each owner's latest task.
///
/// Long-lived work is never started here, or a settle would wait for it: the reconcile loop (`PollLoop`), and a refused
/// wake line's retry (`OperatorWaker`), which waits fifteen seconds on the live clock. Starting work here changes nothing
/// about how it runs: it is an ordinary task, cancelled by the owner that keeps it, and counted only until it returns.
@MainActor
final class OperatorWork {
    /// How many of the tasks started here are still running.
    private(set) var running = 0

    nonisolated init() {}

    /// `body` as a task on the main actor, counted until it returns, cancelled or not.
    @discardableResult
    func start<Value: Sendable>(_ body: @escaping @MainActor () async -> Value) -> Task<Value, Never> {
        running += 1
        return Task { @MainActor in
            let value = await body()
            self.running -= 1
            return value
        }
    }
}
