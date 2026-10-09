import Foundation

/// A monotonic clock a test moves by hand, for what holds an event against the time — a closed task
/// window's hold (`ClosedWindowTriage`).
@MainActor
final class ManualInstant {
    private(set) var now = ContinuousClock.now
    func advance(by duration: Duration) { now = now.advanced(by: duration) }
}
