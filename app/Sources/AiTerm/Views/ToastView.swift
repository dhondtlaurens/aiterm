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
            // It floats over the sidebar, so it is a popover's ground and edge, as `menuChrome` draws them.
            .background(Palette.menu, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.borderStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
            .accessibilityAddTraits(.isStaticText)
    }
}
