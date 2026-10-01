import SwiftUI

/// A plain text field dressed in the house field chrome; `secure` hides what is typed, for a token.
public struct Input: View {
    let placeholder: String
    @Binding var text: String
    var monospaced: Bool
    var secure: Bool
    @FocusState private var focused: Bool

    public init(placeholder: String, text: Binding<String>, monospaced: Bool = false, secure: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.monospaced = monospaced
        self.secure = secure
    }

    public var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: Self.edits(to: $text))
            } else {
                TextField(placeholder, text: Self.edits(to: $text))
            }
        }
        .textFieldStyle(.plain)
        .font(monospaced ? Typography.monoCode : Typography.body)
        .foregroundStyle(Palette.text)
        .focused($focused)
        .fieldChrome(focused: focused)
    }

    /// `binding`, passing on only real edits. AppKit hands the field's value back when editing
    /// begins and ends, not only when the text changes, and a setter with a side effect on the
    /// other end — open the ticket list, mark the branch hand-edited — would then fire because the
    /// user clicked some other field.
    static func edits(to binding: Binding<String>) -> Binding<String> {
        Binding(get: { binding.wrappedValue }, set: { if $0 != binding.wrappedValue { binding.wrappedValue = $0 } })
    }
}
