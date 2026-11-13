import SwiftUI

/// The house push button: one shape with a field — `Size.control` tall, `Radius.control`, the body
/// face, `Space.gap` either side of its label — in two kinds, used as `.buttonStyle(.push(.primary))`.
///
/// | State | Secondary | Primary |
/// | --- | --- | --- |
/// | Default | `Palette.button` fill, 1 pt `Palette.border` edge, `Palette.text` label | `Palette.accent` fill, medium `Palette.onAccent` label, content on `.surface(.accent)` |
/// | Hover | as default: a push button does not answer the pointer before it is pressed, as AppKit's does not | as default |
/// | Pressed | `Palette.controlActive` fill | `Palette.accentPressed` fill |
/// | Disabled | the whole button at `Opacity.disabled` | the same |
/// | Focus | the house `focusRing` at `Radius.control` | the same |
/// | Selected | none: a push button is never selected | none |
///
/// It is a `ButtonStyle`, so the button stays a native `Button`: `.keyboardShortcut`, `.disabled`,
/// `.help` and its accessibility work as they do on AppKit's bezel. Lighter than the ground it stands
/// on, where a field is darker. A caller with keycaps or a mark lays them out in its label
/// (`Space.base` from the title), and the primary's accent surface inks them. In the scaled sidebar it
/// scales its own height, radius and padding (README, Scaling); everywhere else it is drawn at ×1.
public struct PushButtonStyle: ButtonStyle {
    /// The button's weight in its row.
    public enum Kind: Equatable, Sendable {
        /// The sheet's one action on ⌘↩: the accent.
        case primary
        /// Everything else: Cancel, Back, a card's action.
        case secondary
    }

    let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        PushButtonBody(kind: kind, pressed: configuration.isPressed) { configuration.label }
    }

    /// The fill: lighter than its ground at rest, a step lighter again while pressed; the accent dimmed
    /// while pressed.
    static func fill(_ kind: Kind, pressed: Bool) -> Color {
        switch kind {
        case .primary: pressed ? Palette.accentPressed : Palette.accent
        case .secondary: pressed ? Palette.controlActive : Palette.button
        }
    }

    /// The edge: the soft hairline on a secondary button; none on the accent.
    static func edge(_ kind: Kind) -> Color? { kind == .secondary ? Palette.border : nil }

    /// The ground the label is drawn on, which its keycaps and a busy mark read.
    static func surface(_ kind: Kind, around outer: Surface) -> Surface { kind == .primary ? .accent : outer }

    /// The label's ink: the accent's on a primary, the plain text ink on a secondary, whatever row
    /// the button sits in.
    static func ink(_ kind: Kind) -> Color { kind == .primary ? Surface.accent.ink : Palette.text }

    /// The label's face: the body, medium on the accent.
    static func font(_ kind: Kind) -> TypeStyle { kind == .primary ? Typography.bodyEmphasis : Typography.body }

    /// The whole button's opacity: `Opacity.disabled` while it cannot be used.
    static func opacity(enabled: Bool) -> Double { enabled ? 1 : Opacity.disabled }
}

public extension ButtonStyle where Self == PushButtonStyle {
    /// The house push button, `.primary` or `.secondary`.
    static func push(_ kind: PushButtonStyle.Kind) -> PushButtonStyle { PushButtonStyle(kind) }
}

/// What the style draws: a view, so it can read the enabled state, keyboard focus, the scale and the
/// ground it sits on. Internal rather than private so a test can draw it pressed.
struct PushButtonBody<Label: View>: View {
    let kind: PushButtonStyle.Kind
    let pressed: Bool
    @ViewBuilder let label: () -> Label
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.surface) private var surface
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        let radius = scale(Radius.control)
        label()
            .font(PushButtonStyle.font(kind))
            .foregroundStyle(PushButtonStyle.ink(kind))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, scale(Space.gap))
            .frame(height: scale(Size.control))
            .background(RoundedRectangle(cornerRadius: radius).fill(PushButtonStyle.fill(kind, pressed: pressed)))
            .overlay {
                if let edge = PushButtonStyle.edge(kind) {
                    RoundedRectangle(cornerRadius: radius).strokeBorder(edge, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .surface(PushButtonStyle.surface(kind, around: surface))
            .opacity(PushButtonStyle.opacity(enabled: enabled))
            .focusRing(focused, cornerRadius: radius)
    }
}
