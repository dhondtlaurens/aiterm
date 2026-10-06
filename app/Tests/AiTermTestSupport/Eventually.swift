// Debug only: these record issues through swift-testing, whose macros a plain release build of the
// package (the library is built with it, though only tests use it) does not have.
#if DEBUG
import Foundation
import Testing

/// Waits for something a test expects to happen, instead of sleeping for as long as it usually
/// takes. A pass ends the moment `condition` holds, so the wait costs what the thing costs; only a
/// failure waits out `timeout`, which is `TestDeadline`'s so a loaded machine does not flake it.
///
/// `condition` is checked in the caller's isolation, between turns of its executor, so a test on
/// the main actor reads its own state and the thing it waits for can run on that actor meanwhile.
/// A timeout is recorded as an issue, at the caller's line and saying what was waited for, so a
/// caller that ignores the result still fails. It also returns whether the condition held, for a
/// test that wants to stop there (`try #require(await eventually …)`).
///
/// Only for what is *expected*. A test that shows something does not happen keeps a fixed window,
/// which stays as short as it can be.
@discardableResult
func eventually(describing what: @autoclosure () -> String = "the condition", timeout: TimeInterval = TestDeadline.seconds,
                every interval: Duration = .milliseconds(5), sourceLocation: SourceLocation = #_sourceLocation,
                isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Task.isCancelled { return false }
        if Date() >= deadline {
            Issue.record("Timed out after \(timeout) s waiting for \(what())", sourceLocation: sourceLocation)
            return false
        }
        try? await Task.sleep(for: interval)
    }
    return true
}
#endif
