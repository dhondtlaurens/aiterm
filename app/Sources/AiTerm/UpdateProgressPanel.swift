import AppKit
import Synchronization
import AiTermUI

/// The small "Downloading AiTerm 0.3.0…" window shown while an update downloads and is verified —
/// the alert itself cannot show progress — and while the update scripts bring the workspace forward
/// at launch. Stock AppKit controls; spacing from `Space`.
@MainActor
enum UpdateProgressPanel {
    /// Shows the panel and returns the call that closes it.
    static func show(_ text: String) -> () -> Void {
        let panel = make(text)
        panel.makeKeyAndOrderFront(nil)
        return { panel.close() }
    }

    /// Shows the panel while `work` runs on a thread of its own, and returns once it has, with its
    /// error. The main thread waits in the panel's modal session, so the spinner turns and nothing
    /// else of the launch runs meanwhile.
    static func showWhile(_ text: String, _ work: @escaping @Sendable () throws -> Void) throws {
        let panel = make(text)
        let outcome = Mutex<Result<Void, any Error>?>(nil)
        let thread = Thread {
            outcome.withLock { $0 = Result { try work() } }
            // Queued on the main queue, which the modal session serves: it runs once the session has started.
            DispatchQueue.main.async { NSApp.stopModal() }
        }
        thread.name = "AiTerm workspace update"
        thread.start()
        NSApp.runModal(for: panel)
        panel.close()
        try outcome.withLock { $0 }?.get()
    }

    private static func make(_ text: String) -> NSPanel {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning; spinner.controlSize = .small; spinner.startAnimation(nil)
        let stack = NSStackView(views: [spinner, NSTextField(labelWithString: text)])
        stack.orientation = .horizontal; stack.spacing = Space.base
        stack.edgeInsets = NSEdgeInsets(top: Space.block, left: Space.block, bottom: Space.block, right: Space.block)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: stack.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "AiTerm"
        panel.isReleasedWhenClosed = false
        panel.contentView = stack
        panel.center()
        return panel
    }
}
