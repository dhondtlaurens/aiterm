import SwiftUI
import AiTermUI
import AiTermCore

struct ToastView: View {
    let toast: ToastMessage
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        Label(toast.message, systemImage: toast.symbol)
            .font(Typography.label)
            .foregroundStyle(Palette.text)
            .padding(.horizontal, scale(Space.gap))
            .padding(.vertical, scale(Space.base))
            .background(Palette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
            .accessibilityAddTraits(.isStaticText)
    }
}
