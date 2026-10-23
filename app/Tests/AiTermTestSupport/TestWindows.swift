import AppKit
import SwiftUI
import AiTermTestWindowHook

// Windows for tests. AppKit animates a window's opening and closing (NSWindowTransformAnimation) as
// a threaded NSAnimation on a user-interactive global queue. A test window that is covered, or a
// host app in the background, can stall that animation, and each stall parks a GCD worker: once
// about 64 are parked (`kern.wq_max_constrained_threads`) nothing dispatched to a global queue
// runs again — every `BackgroundWork.run` and `asyncAfter` in the tests included — and the suite
// hangs with its windows still open. So a test process animates none: every window comes from here.
//
// Every window is also hidden — transparent and click-through — however it was made: the hook in
// AiTermTestWindowHook does that to each one the test process orders in, so a run does not draw
// over the person's apps. `keepVisible` is the way out for a window that must be seen.

/// Turns window animations off for the whole test process. A static initialiser, so the first call
/// does it, once, whichever test reaches a window first; every helper below calls it before it makes
/// a window.
@MainActor private enum WindowAnimations {
    static let off: Void = {
        UserDefaults.standard.register(defaults: ["NSAutomaticWindowAnimationsEnabled": false])
    }()
}

/// Turns window animations off if nothing has yet. For a window a test makes some other way.
@MainActor private func disableWindowAnimations() {
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

/// Leaves `window` drawn and clickable when it is ordered in, which every other test window is not:
/// for a test that needs the window server to show or hit-test it. Sent events and `cacheDisplay`
/// work on a hidden window, so few tests do. Call it before the window is first ordered in: it stops
/// the hiding and does not undo it, so a window already ordered in stays transparent. It covers
/// `window` alone; its sheets, child windows and popovers are windows of their own, and are hidden.
@MainActor public func keepVisible(_ window: NSWindow) {
    AiTermTestKeepWindowVisible(window)
}

/// Whether the login session's screen is locked. While it is, the login window owns key focus, and
/// no window of the test process becomes key however it is asked — a test that needs a key window
/// can only time out, so it runs `.enabled(if: !LoginSession.isLocked)` instead.
public enum LoginSession {
    public static var isLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

/// Hosts an AppKit view at its existing frame. The caller closes or orders out the window.
@MainActor public func testWindow(hosting host: NSView, styleMask: NSWindow.StyleMask = [.titled], orderFront: Bool = true) -> NSWindow {
    let window = testWindow(contentRect: host.frame, styleMask: styleMask)
    window.contentView = host
    if orderFront { window.makeKeyAndOrderFront(nil) }
    return window
}

/// Prepares a SwiftUI host without adding a window or running the run loop.
@MainActor public func testHost<V: View>(_ view: V, size: CGSize? = nil,
                                       appearance: NSAppearance? = nil) -> NSHostingView<V> {
    let host = NSHostingView(rootView: view)
    if let appearance { host.appearance = appearance }
    host.frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
    return host
}

/// Hosts SwiftUI at a specified size or its fitting size, in the app's dark appearance.
@MainActor public func testWindow<V: View>(hosting view: V, size: CGSize? = nil) -> (NSWindow, NSHostingView<V>) {
    let host = testHost(view, size: size, appearance: NSAppearance(named: .darkAqua))
    let window = testWindow(hosting: host)
    host.layoutSubtreeIfNeeded()
    return (window, host)
}

/// A key press addressed to a hosted test window.
@MainActor public func keyDown(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent? {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
}
