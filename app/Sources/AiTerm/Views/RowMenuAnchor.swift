import AppKit
import SwiftUI

/// Opens a row's context menu from the keyboard: ↩ on an empty project header, which has nothing to
/// fold, opens its menu instead.
///
/// SwiftUI has no call that presents a `.contextMenu`, so the anchor — a view in the row's
/// background — right-clicks the row where it sits, and the menu is the one a click brings up, item
/// for item. A ↓ queued as its tracking begins highlights the first enabled item, so the arrows, ↩
/// and ⎋ work on it at once, as on a menu-bar menu opened from the keyboard.
struct RowMenuAnchor: NSViewRepresentable {
    let id: UUID

    /// Each row's anchor, by the row's id; weak, so a row gone from the list drops out.
    private static let anchors = NSMapTable<NSUUID, Anchor>.strongToWeakObjects()

    final class Anchor: NSView {
        /// The row it is registered for; a reused row's anchor is registered for another id later.
        fileprivate(set) var id: UUID?

        /// Clicks go through to the row it sits behind.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// A right-click on the row's bottom leading corner, so the menu drops below the row.
        var rightClick: NSEvent? {
            guard let window else { return nil }
            let corner = convert(NSPoint(x: bounds.minX + 1, y: isFlipped ? bounds.maxY - 1 : bounds.minY + 1), to: nil)
            return NSEvent.mouseEvent(with: .rightMouseDown, location: corner, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }

        /// Returns once the menu has closed: AppKit tracks it modally.
        func openMenu() {
            guard let window, let click = rightClick,
                  let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: click.timestamp,
                                              windowNumber: window.windowNumber, context: nil,
                                              characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                                              isARepeat: false, keyCode: 125)
            else { return }
            // Queued, not sent: the menu's tracking loop reads it from the event queue once it runs.
            // The notification comes on the main thread, inside `sendEvent` below.
            nonisolated(unsafe) let arrow = down
            let tracking = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                                  object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { NSApp.postEvent(arrow, atStart: false) }
            }
            defer { NotificationCenter.default.removeObserver(tracking) }
            window.sendEvent(click)
        }
    }

    /// The anchor behind the row `id` names, while it is on screen.
    static func anchor(for id: UUID) -> Anchor? {
        anchors.object(forKey: id as NSUUID).flatMap { $0.window == nil || $0.id != id ? nil : $0 }
    }

    /// Registers `anchor` for `id`, and drops the id it was registered for before, unless another
    /// anchor has taken that id since.
    private static func register(_ anchor: Anchor, for id: UUID) {
        if let old = anchor.id, old != id, anchors.object(forKey: old as NSUUID) === anchor {
            anchors.removeObject(forKey: old as NSUUID)
        }
        anchor.id = id
        anchors.setObject(anchor, forKey: id as NSUUID)
    }

    /// Opens the context menu of the row `id` names, if it is on screen. Whether it was.
    @discardableResult
    static func openMenu(for id: UUID) -> Bool {
        guard let anchor = anchor(for: id) else { return false }
        anchor.openMenu()
        return true
    }

    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor(frame: .zero)
        Self.register(anchor, for: id)
        return anchor
    }

    // A reused row can come back for another id.
    func updateNSView(_ anchor: Anchor, context: Context) {
        Self.register(anchor, for: id)
    }
}
