import AppKit
import SwiftUI

/// Binding and focus synchronization shared by the native single-line fields. Field construction,
/// secure entry, caret placement and popup commands remain the owning control's responsibility.
@MainActor
final class TextFieldEditing {
    weak var field: NSTextField?
    private var text: Binding<String>
    private var focused: Binding<Bool>
    private var undoObservers: [NSObjectProtocol] = []

    init(text: Binding<String>, focused: Binding<Bool>) {
        self.text = Self.edits(to: text)
        self.focused = focused
        // Undo/redo changes the editor without the notification a keystroke sends. The window's
        // undo manager is shared: only a field with the current editor can publish its text.
        undoObservers = [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.editorChanged() }
            }
        }
    }

    isolated deinit { undoObservers.forEach(NotificationCenter.default.removeObserver) }

    /// Refresh the bindings on every SwiftUI update, without resetting selection for unchanged text.
    func update(_ field: NSTextField, text: Binding<String>, focused: Binding<Bool>, placeholder: String) {
        self.field = field
        self.text = Self.edits(to: text)
        self.focused = focused
        if field.stringValue != text.wrappedValue { field.stringValue = text.wrappedValue }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
    }

    /// `binding`, passing on only real edits. A setter can have a side effect on the other end —
    /// open the ticket list, mark the branch hand-edited — that a value handed back unchanged, as
    /// a field does when editing begins or ends, must not fire.
    static func edits(to binding: Binding<String>) -> Binding<String> {
        Binding(get: { binding.wrappedValue }, set: { if $0 != binding.wrappedValue { binding.wrappedValue = $0 } })
    }

    func focusBegan() { if !focused.wrappedValue { focused.wrappedValue = true } }
    func focusEnded() { if focused.wrappedValue { focused.wrappedValue = false } }

    func textChanged(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        text.wrappedValue = field.stringValue
    }

    private func editorChanged() {
        guard let editor = field?.currentEditor() else { return }
        text.wrappedValue = editor.string
    }
}
