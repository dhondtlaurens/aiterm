import AppKit

/// Turns the main run loop until `condition` holds, for what a hosted view needs the run loop to do
/// — SwiftUI pushing a state change into AppKit, a deferred `RunLoop.main.perform`. It is the
/// run-loop twin of `eventually`: a fixed spin is slow on a fast machine and too short on a loaded
/// one. A main-actor test cannot `await` its way there, because nothing else runs while it holds
/// the actor; `DispatchQueue.main.async` never runs inside one at all.
///
/// Returns whether the condition held. `timeout` is `TestDeadline`'s: a pixel test that holds the
/// main thread for seconds must not make a wait that would have passed fail.
@MainActor @discardableResult
func pumpRunLoop(timeout: TimeInterval = TestDeadline.seconds, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    return true
}

/// Turns the main run loop until `condition` holds, laying `host` out between turns, so a test
/// reads what SwiftUI pushed into a hosted AppKit view once it has. Returns whether it held.
@MainActor @discardableResult
func settle(_ host: NSView, timeout: TimeInterval = TestDeadline.seconds, until condition: () -> Bool) -> Bool {
    let held = pumpRunLoop(timeout: timeout) {
        host.layoutSubtreeIfNeeded()
        return condition()
    }
    host.layoutSubtreeIfNeeded()
    return held
}

/// One fixed spin of the run loop, then layout, for a change that has nothing to wait *on* — a
/// resize, say, where what is read afterwards is the same before and after. Prefer
/// ``settle(_:timeout:until:)``: a fixed spin is too long on a fast machine and too short on a loaded one.
@MainActor
func settle(_ host: NSView, for seconds: TimeInterval = 0.05) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    host.layoutSubtreeIfNeeded()
}

extension NSView {
    /// The first descendant of `type`, depth first.
    func firstDescendant<T: NSView>(_ type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstDescendant(type) { return match }
        }
        return nil
    }
}
