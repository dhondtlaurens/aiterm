import AppKit
import CoreGraphics
import AiTermCore

extension PauseGate {
    /// The Mac's own record of your last key and click (`CGEventSource`, which needs no permission), counted
    /// only while iTerm2 or AiTerm is the frontmost app. A click in AiTerm's sidebar while iTerm2 stays in
    /// front counts too, since the sidebar does not take the front.
    static let live = PauseGate(idle: {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard front == ItermPreferences.bundleIdentifier || (front != nil && front == Bundle.main.bundleIdentifier) else { return nil }
        let inputs: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return inputs.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min()
    })
}
