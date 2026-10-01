import SwiftUI
import AiTermUI

/// One field, one name. The sheet behind New terminal, Add divider and the renames of a task, a
/// review, a terminal and a divider: every flow whose whole question is "what should this be
/// called?".
///
/// It has no steps, so its band always holds its one sentence (`SheetSubtitle`). A sheet that opens
/// a window — New terminal — ends its content with its `DestinationLine`.
///
/// It is a pattern, not a primitive: it composes `SheetLayout` and `SheetActionRow`, which encode
/// where *this app* puts a sheet's nav, content and actions.
struct NameSheet: View {
    let title: String
    let subtitle: String
    let fieldLabel: String
    let placeholder: String
    let help: String?
    let destination: Destination?
    let confirmLabel: String
    let canSubmit: Bool
    let submit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    // `@State` is a macro in the macOS 26 SDK and its SwiftUIMacros plugin ships only with Xcode,
    // which this machine does not have; this is the storage and accessor the macro would generate.
    var _name: State<String>
    private var name: String {
        get { _name.wrappedValue }
        nonmutating set { _name.wrappedValue = newValue }
    }

    init(title: String, subtitle: String, fieldLabel: String, placeholder: String, help: String? = nil,
         destination: Destination? = nil, confirmLabel: String, initialName: String, canSubmit: Bool,
         submit: @escaping (String) -> Void) {
        self.title = title; self.subtitle = subtitle; self.fieldLabel = fieldLabel; self.placeholder = placeholder
        self.help = help; self.destination = destination
        self.confirmLabel = confirmLabel; self.canSubmit = canSubmit; self.submit = submit
        _name = State(initialValue: initialName)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        SheetLayout(title: title, height: Sheet.height) {
            SheetSubtitle(subtitle)
        } content: {
            FormField(fieldLabel) {
                Input(placeholder: placeholder, text: _name.projectedValue)
                if let help { HelpText(help) }
                if let destination { DestinationLine(destination) }
            }
        } footer: {
            SheetActionRow {
                Button("Cancel") { dismiss.afterThisEvent() }.keyboardShortcut(.cancelAction)
                SheetPrimaryButton(title: confirmLabel, enabled: canSubmit, action: confirm)
            }
        }
    }

    /// The name reaches `submit` trimmed. What an empty one means is the caller's business: a new
    /// terminal falls back to its suggestion, a divider draws a plain rule, a renamed task or
    /// terminal keeps its name.
    private func confirm() {
        guard canSubmit else { return }
        submit(trimmed)
        dismiss.afterThisEvent()
    }
}

extension NameSheet {
    /// Add divider, as the sidebar and the snapshots both build it.
    static func newDivider(canSubmit: Bool, submit: @escaping (String) -> Void) -> NameSheet {
        NameSheet(title: "Add divider", subtitle: "Groups the projects under it in the sidebar.",
                  fieldLabel: "Divider name", placeholder: "Work", help: "Leave it empty for a plain rule.",
                  confirmLabel: "Add Divider", initialName: "", canSubmit: canSubmit, submit: submit)
    }

    /// Rename a task, a review, a terminal or a divider: the copy is the target's own.
    static func rename(_ target: AppController.RenameTarget, canSubmit: Bool,
                       submit: @escaping (String) -> Void) -> NameSheet {
        NameSheet(title: target.title, subtitle: target.subtitle, fieldLabel: target.fieldLabel,
                  placeholder: target.name, confirmLabel: "Rename", initialName: target.name,
                  canSubmit: canSubmit, submit: submit)
    }
}
