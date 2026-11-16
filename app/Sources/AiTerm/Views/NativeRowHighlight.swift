import AppKit
import ObjectiveC
import SwiftUI

/// Turns off the row highlight `List(selection:)` brings with it.
///
/// The list is there for its native keyboard navigation, which needs AppKit's selection to stay
/// live — so the selection is kept and only its *drawing* is dropped, leaving every state to the
/// row's own pill. AppKit paints the whole row rect; the pill sits inside the row's indent and
/// content frame, and no amount of padding reconciles the two while both are drawing.
///
/// The probe rides in the list's background, so it finds the table by walking out one ancestor at
/// a time and searching each one's subtree — the nearest table is this list's own.
struct NativeRowHighlight: NSViewRepresentable {
    static let off = NativeRowHighlight()

    final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        override func layout() { super.layout(); apply() }

        /// Found once and kept: `layout()` runs on every sidebar render, and the search walks whole
        /// subtrees. Weak, and looked up again once it has left the window.
        private weak var found: NSTableView?

        func apply() {
            ContextMenuHighlight.silence()
            if let found, found.window != nil, found.window === window {
                found.selectionHighlightStyle = .none
                return
            }
            guard let table = NativeRowHighlight.table(near: self) else { return }
            table.selectionHighlightStyle = .none
            found = table
        }
    }

    /// The table of the list `view` rides in the background of: each ancestor's subtree is searched in
    /// turn, outward, so the nearest table is that list's own.
    static func table(near view: NSView) -> NSTableView? {
        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        var ancestor = view.superview
        while let current = ancestor {
            if let table = table(in: current) { return table }
            ancestor = current.superview
        }
        return nil
    }

    func makeNSView(context: Context) -> Probe { Probe(frame: .zero) }
    // SwiftUI rebuilds the table's rows as the workspace changes; re-applied here so a rebuilt
    // table cannot come back with the highlight on.
    func updateNSView(_ view: Probe, context: Context) { view.apply() }
}

/// Turns off the *other* row highlight AppKit brings: the ring it draws around a row whose context
/// menu is open.
///
/// ``NativeRowHighlight`` reaches only `NSTableRowView.drawSelectionInRect:`. This one is painted by
/// the table itself, on the whole row rect — measured at 26 pt wider on the leading edge and 8 pt
/// taller than the row's pill — so a right-click summoned a third state, larger than both hover and
/// selection, over the pill the canvas asks for. Same two painters, same two rectangles, a different
/// door.
///
/// AppKit publishes no switch for it. The drawing does funnel through a single per-row override
/// point, `drawContextMenuHighlightForRow:`, which is replaced here with a no-op; with the ring gone
/// the pill is again the sidebar's only painter. The selector is looked up by name and the swap is
/// skipped if it is missing, so a future AppKit that renames it brings the ring back rather than
/// stopping the app — `SidebarContextMenuHighlightTests` is what notices.
enum ContextMenuHighlight {
    private static let silenced: Bool = {
        guard let painter = class_getInstanceMethod(NSTableView.self,
                                                    NSSelectorFromString("drawContextMenuHighlightForRow:"))
        else { return false }
        let nothing: @convention(block) (AnyObject, Int) -> Void = { _, _ in }
        method_setImplementation(painter, imp_implementationWithBlock(nothing))
        return true
    }()

    /// Idempotent: the swap happens once, on whichever row view is built first.
    @discardableResult static func silence() -> Bool { silenced }
}
