import Foundation

/// Blocking filesystem/process work belongs on a Dispatch queue, not Swift's
/// cooperative executor. Callers retain ownership of cancellation and stale results.
public enum BackgroundWork {
    /// `queue` is a caller's own when its work must be serialised — `TaskWorkflow` keeps every git
    /// mutation on one queue — and the shared concurrent one otherwise.
    public static func run<Value: Sendable>(on queue: DispatchQueue = .global(qos: .userInitiated),
                                            _ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}
