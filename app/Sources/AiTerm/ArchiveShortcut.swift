import AppKit

/// Local key routing runs before Edit › Select All can claim the Archive's key on the sidebar.
@MainActor final class ArchiveShortcut {
    private var monitor: Any?
    private let openArchive: () -> Void
    init(openArchive: @escaping () -> Void) { self.openArchive = openArchive }
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                return Self.perform(event, firstResponder: NSApp.keyWindow?.firstResponder, openArchive: self.openArchive)
            }
            return handled ? nil : event
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    static func perform(_ event: NSEvent, firstResponder: NSResponder?, openArchive: () -> Void) -> Bool {
        guard event.type == .keyDown, event.charactersIgnoringModifiers?.lowercased() == "a",
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else { return false }
        if let text = firstResponder as? NSTextView, text.isEditable { text.selectAll(nil) }
        else if let field = firstResponder as? NSTextField, let text = field.currentEditor() { text.selectAll(nil) }
        else { openArchive() }
        return true
    }
}
