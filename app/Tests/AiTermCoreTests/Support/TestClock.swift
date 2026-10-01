import Foundation
import Synchronization

/// A clock a test moves by hand. A resolver reads its clock from whichever thread asks it, so the
/// time lives behind a lock rather than in a `var` the `now` closure captures.
final class TestClock: Sendable {
    private let date: Mutex<Date>
    init(_ start: Date = Date(timeIntervalSince1970: 0)) { date = Mutex(start) }

    var now: Date { date.withLock { $0 } }
    func advance(by seconds: TimeInterval) { date.withLock { $0 += seconds } }
}
