import AppKit

// Windows for tests. AppKit animates a window's opening and closing (NSWindowTransformAnimation) as
// a threaded NSAnimation on a user-interactive global queue. A test window that is covered, or a
// host app in the background, can stall that animation, and each stall parks a GCD worker: once
// about 64 are parked (`kern.wq_max_constrained_threads`) nothing dispatched to a global queue
// runs again — every `BackgroundWork.run` and `asyncAfter` in the tests included — and the suite
// hangs with its windows still open. So a test process animates none: every window comes from here.

/// Turns window animations off for the whole test process. A static initialiser, so the first call
/// does it, once, whichever test reaches a window first; every helper below calls it before it makes
/// a window.
@MainActor private enum WindowAnimations {
    static let off: Void = {
        UserDefaults.standard.set(false, forKey: "NSAutomaticWindowAnimationsEnabled")
    }()
}

/// Turns window animations off if nothing has yet. For a window a test makes some other way.
@MainActor public func disableWindowAnimations() {
    _ = WindowAnimations.off
}

/// A window with no open or close animation, kept alive when closed (the test closes it, and ARC
/// owns it), made at `contentRect` in `styleMask`. The caller orders it front and closes it.
@MainActor public func testWindow(contentRect: NSRect, styleMask: NSWindow.StyleMask = []) -> NSWindow {
    disableWindowAnimations()
    let window = NSWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.animationBehavior = .none
    return window
}

/// `testWindow`, as a panel.
@MainActor public func testPanel(contentRect: NSRect, styleMask: NSWindow.StyleMask = []) -> NSPanel {
    disableWindowAnimations()
    let panel = NSPanel(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    return panel
}
