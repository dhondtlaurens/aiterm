import SwiftUI
import AiTermUI

/// The picked field and chip's clear glyph. An omitted label preserves the field's
/// current native accessibility name; chips already supply their tooltip as the label.
struct PickerClearButton: View {
    let help: String
    var accessibilityLabel: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(Typography.micro).foregroundStyle(Palette.muted)
        }
        .buttonStyle(.plain).help(help)
        .modifier(OptionalAccessibilityLabel(label: accessibilityLabel))
    }
}

private struct OptionalAccessibilityLabel: ViewModifier {
    let label: String?
    func body(content: Content) -> some View {
        if let label { content.accessibilityLabel(label) } else { content }
    }
}
