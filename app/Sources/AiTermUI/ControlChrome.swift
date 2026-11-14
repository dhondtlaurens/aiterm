import SwiftUI

// The house chrome every control in the app is dressed in: the focus ring, the field box, the
// group box, a dropdown row's highlight, and the one elevation anything hanging off a field is given.

/// The focus ring's edge: a one-point stroke on the control's own edge, in `Palette.focusEdge`.
/// Belongs to `focusRing` alone, and to nothing `Metrics` names; a stroke, so it does not scale.
private let focusEdgeWidth: CGFloat = 1
/// The focus ring's halo outside that edge, in `Palette.focusRing`: its stroke width and its outset,
/// which have to stay equal so the halo never bleeds inside the control it sits outside.
private let focusHaloWidth: CGFloat = 3

public extension View {
    /// The house focus ring. One modifier, so a control that gains keyboard focus does not have to
    /// reinvent it — it used to exist only inside `fieldChrome`, which left focus invisible on
    /// everything that is not a text field.
    ///
    /// Two parts: a 1 pt `focusEdge` stroke on the control's own edge, which says which control has
    /// the keyboard, and a 3 pt `focusRing` halo *outside* it at 22 %, a hint rather than a second
    /// border competing with a segmented track's own. The halo's corner is the control's plus its
    /// width, so the two stay concentric.
    func focusRing(_ focused: Bool, cornerRadius: CGFloat = Radius.control) -> some View {
        overlay(RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(focused ? Palette.focusEdge : .clear, lineWidth: focusEdgeWidth))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius + focusHaloWidth)
                .strokeBorder(focused ? Palette.focusRing : .clear, lineWidth: focusHaloWidth)
                .padding(-focusHaloWidth))
    }

    /// The one panel anything that hangs off a field is drawn in: the `menu` fill, the firm
    /// `borderStrong` edge and one elevation. The ticket list and the completion popup used to be
    /// 4 px apart in y and 2 px apart in blur, for no reason anyone could name — and both sat on the
    /// sheet's own `surface`, so over a field or a line of text they read as having no background at
    /// all. At `Radius.panel`, or at the radius of what it lies over: a background card takes its row
    /// pill's `Radius.control`.
    func menuChrome(cornerRadius: CGFloat = Radius.panel) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(Palette.menu))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Palette.borderStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
    }

    /// The box a group of controls is drawn in: the card ground (`surfaceRaised`) inside the soft
    /// hairline, at the group radius — a Settings card, each of the Interface tab's groups, a question
    /// waiting on you. A question edges itself in `Palette.statusChipAttentionStroke` while it waits; a
    /// segmented track passes `field` and `borderStrong`, as a field is drawn.
    func groupChrome(fill: Color = Palette.surfaceRaised, edge: Color = Palette.border) -> some View {
        background(RoundedRectangle(cornerRadius: Radius.group).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: Radius.group).strokeBorder(edge, lineWidth: 1))
    }

    /// A dropdown row's highlight — a neutral wash (`menuHighlight`) behind the row the keyboard or
    /// the pointer is on, stronger (`menuHighlightPressed`) while the pointer holds it down — and the
    /// ground every row declares: `.sheet`, highlighted or not. The highlight is neutral, so a
    /// highlighted row keeps its resting inks, its link-coloured key and its brand marks; declaring
    /// it here keeps a row inside a sidebar-declared popup inking for the popup, not the sidebar. The
    /// ticket, merge request and branch pickers and the prompt's completion popup all draw their
    /// rows in it.
    func menuRowHighlight(_ on: Bool, pressed: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: Radius.chip)
            .fill(pressed ? Palette.menuHighlightPressed : (on ? Palette.menuHighlight : .clear)))
            .surface(.sheet)
    }

    /// A single-line text input's chrome: the field's own padding, `Size.control` tall, full
    /// width, in the field box.
    func fieldChrome(focused: Bool = false) -> some View {
        padding(.horizontal, Space.inset)
            .frame(height: Size.control)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fieldBox(focused: focused)
    }

    /// A chip's fill and optional unscaled hairline at the environment's chip radius. Callers own
    /// their padding and height; a quiet badge can outset this box without moving its label.
    func chipChrome(fill: Color, stroke: Color? = nil) -> some View {
        modifier(ChipChrome(fill: fill, stroke: stroke))
    }

    /// The box every text input and `Select` sits in — the `field` ground, darker than what holds
    /// it, inside the firm `borderStrong` edge — and its focus ring; without `fieldChrome`'s padding
    /// and height, for a field that sizes and insets itself: the prompt editor.
    func fieldBox(focused: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: Radius.control).fill(Palette.field))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Palette.borderStrong, lineWidth: 1))
            .focusRing(focused)
    }
}

private struct ChipChrome: ViewModifier {
    let fill: Color
    let stroke: Color?
    @Environment(\.interfaceScale) private var scale

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: scale(Radius.chip)).fill(fill))
            .overlay {
                if let stroke { RoundedRectangle(cornerRadius: scale(Radius.chip)).strokeBorder(stroke, lineWidth: 1) }
            }
    }
}
