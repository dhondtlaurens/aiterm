import AppKit
import SwiftUI

/// Lets ↓ and ↑ cross the fold between OPERATOR and PROJECTS (`AppController.crossSections(down:)`).
///
/// The list holds only the open section's rows, so its own arrows stop at the section's edge. The table
/// takes the arrows before a SwiftUI key handler would see them, so a local monitor looks first — only
/// while this list's table is first responder, and only at the edge: everywhere else the key goes on
/// to the table untouched.
struct SectionCrossing: NSViewRepresentable {
    let cross: @MainActor (_ down: Bool) -> Bool

    final class Probe: NSView {
        var cross: @MainActor (Bool) -> Bool = { _ in false }
        private var monitor: Any?
        /// Found on the first arrow and kept, as ``NativeRowHighlight`` keeps its own.
        private weak var table: NSTableView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { start() }
        }

        private func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, let down = SectionCrossing.direction(of: event) else { return false }
            if table?.window !== window { table = NativeRowHighlight.table(near: self) }
            guard let table, window.firstResponder === table else { return false }
            return cross(down)
        }

        isolated deinit { stop() }
    }

    /// ↓ is true, ↑ false; nil for any other key, or an arrow with a modifier, which the table keeps.
    static func direction(of event: NSEvent) -> Bool? {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty else { return nil }
        switch event.specialKey {
        case .downArrow?: return true
        case .upArrow?: return false
        default: return nil
        }
    }

    func makeNSView(context: Context) -> Probe { Probe(frame: .zero) }
    func updateNSView(_ view: Probe, context: Context) { view.cross = cross }
}
