import Foundation

/// Waits for something a test expects to happen, instead of sleeping for as long as it usually
/// takes. A pass ends the moment `condition` holds, so the wait costs what the thing costs; only a
/// failure waits out `timeout`, which is `TestDeadline`'s so a loaded machine does not flake it.
///
/// `condition` is checked in the caller's isolation, between turns of its executor, so a test on
/// the main actor reads its own state and the thing it waits for can run on that actor meanwhile.
/// Returns whether the condition held, for a test that wants to `#require` it.
///
/// Only for what is *expected*. A test that shows something does not happen keeps a fixed window,
/// which stays as short as it can be.
@discardableResult
func eventually(timeout: TimeInterval = TestDeadline.seconds, every interval: Duration = .milliseconds(5),
                isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline || Task.isCancelled { return false }
        try? await Task.sleep(for: interval)
    }
    return true
}
