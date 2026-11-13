import Foundation

/// Blocking filesystem/process work belongs on a Dispatch queue, not Swift's
/// cooperative executor. Callers retain ownership of cancellation and stale results.
///
/// Which to use for blocking work:
/// - `BackgroundWork`: work that ends on its own within a deadline — git, a file read, a process
///   run with a timeout. On the shared pool at the caller's `priority`, or on a caller's own serial
///   queue (a repository's lane, `GitLanes`) when its jobs must not interleave.
/// - `SerialThread`: jobs that must run one at a time and can block for seconds or wait on something
///   outside the app — a Wi-Fi join, the workspace's writer. A thread of its own, so a held job never
///   parks a Dispatch worker the cooperative pool shares (`ProcessRunner` says why that matters).
/// - `ThreadWork`: one such call on its own — an admin prompt that waits on the person, a Keychain read.
public enum BackgroundWork {
    /// `queue` is a caller's own when its work must be serialised — a repository's lane — and the
    /// shared concurrent one at `priority` otherwise: `.utility` for polling no one is waiting on, so it
    /// yields to what the person asked for. It throws what `work` throws and nothing else, so work that
    /// cannot fail is awaited without a `try`.
    public static func run<Value: Sendable, Failure: Error>(priority: DispatchQoS.QoSClass = .userInitiated, on queue: DispatchQueue? = nil,
                                                            _ work: @escaping @Sendable () throws(Failure) -> Value) async throws(Failure) -> Value {
        let queue = queue ?? .global(qos: priority)
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Value, Failure>, Never>) in
            queue.async { continuation.resume(returning: Result { () throws(Failure) -> Value in try work() }) }
        }
        return try result.get()
    }
}


extension BackgroundWork {
    /// The work did not answer within the limit.
    public struct NoAnswer: Error { public init() {} }

    /// `work`, or `NoAnswer` when it has not ended within `limit`. The race is between two tasks started here, not a task
    /// group, so a host call that ignores cancellation is left behind instead of holding the answer up. The loser is
    /// cancelled, `work` too unless `cancelling` is false: a wait that must go on after the answer (an Oracle's critique).
    @MainActor public static func within<Value: Sendable>(_ limit: Duration, cancelling: Bool = true,
                                        _ work: @escaping @MainActor @Sendable () async throws -> Value) async -> Result<Value, any Error> {
        let (finished, report) = AsyncStream<Result<Value, any Error>>.makeStream()
        let working = Task { @MainActor in
            do { report.yield(.success(try await work())) } catch { report.yield(.failure(error)) }
        }
        let timer = Task {
            try await Task.sleep(for: limit)
            report.yield(.failure(NoAnswer()))
        }
        var first: Result<Value, any Error> = .failure(NoAnswer())
        for await result in finished { first = result; break }
        if cancelling { working.cancel() }
        timer.cancel()
        return first
    }
}
