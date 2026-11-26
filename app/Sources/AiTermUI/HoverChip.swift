import SwiftUI

/// A one-line chip raised above what the pointer is over, at once, with no tooltip delay: the footer's
/// `resets Sat 12:00` over a usage reading, a sidebar badge's `Done`, `Approved` or `Merged`.
///
/// `Size.chip` tall, `Space.tight` across, in `Typography.help` (tabular), on the popover's ground
/// (`Palette.menu`) inside its firm edge (`Palette.borderStrong`), so the row it rises over does not show
/// through. Its words default to `Palette.text`; a caller can recede some of them by styling its own `Text`.
/// It sits at its own width, whatever raised it.
public struct HoverChip: View {
    private let text: Text
    @Environment(\.interfaceScale) private var scale

    public init(_ text: Text) { self.text = text }
    public init(_ words: String) { self.init(Text(words)) }

    public var body: some View {
        text
            .foregroundStyle(Palette.text)
            .font(Typography.help.tabular)
            .lineLimit(1)
            .padding(.horizontal, scale(Space.tight))
            .frame(height: scale(Size.chip))
            .chipChrome(fill: Palette.menu, stroke: Palette.borderStrong)
            .fixedSize()
    }
}

extension View {
    /// Raises `chip` above this view while `shown`: centered on this view, or with its trailing edge on this view's
    /// when `alignment` is `.trailing` (a mark at a row's end, whose chip would otherwise run past the sheet), its foot
    /// `Space.hairline` clear of this view's head. It takes no clicks, so the pointer stays on what raised it.
    public func raisingHoverChip(_ chip: HoverChip?, shown: Bool, alignment: HorizontalAlignment = .center) -> some View {
        modifier(RaisesHoverChip(chip: chip, shown: shown, alignment: alignment))
    }
}

private struct RaisesHoverChip: ViewModifier {
    let chip: HoverChip?
    let shown: Bool
    let alignment: HorizontalAlignment
    @Environment(\.interfaceScale) private var scale

    func body(content: Content) -> some View {
        content.overlay(alignment: Alignment(horizontal: alignment, vertical: .top)) {
            if shown, let chip {
                chip
                    .offset(y: -(scale(Size.chip) + scale(Space.hairline)))
                    .allowsHitTesting(false)
            }
        }
    }
}
