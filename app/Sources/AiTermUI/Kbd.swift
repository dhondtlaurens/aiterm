import SwiftUI

/// Keycaps for a shortcut: restated on a primary button's label, or listed in Settings.
///
/// Pass the glyphs macOS menus use: `⌘`, `↩` (U+21A9, not U+23CE — which reads heavier at this
/// size), `⎋`, `⇧`. The caps ink for the ground they sit on, read from `@Environment(\.surface)`:
/// on the accent — a primary button's label declares `.surface(.accent)` — `Palette.onAccent` on
/// the keycap washes, which only hold against the accent; anywhere else the surface's ink on its
/// badge wash, edged in the hairline, as the Keyboard settings list has them.
public struct Kbd: View {
    /// The glyphs, in the order they are drawn.
    private let keys: [String]
    @Environment(\.surface) private var surface

    /// The gap between two caps. Narrower than `Space.tight`: the caps are a single token read as
    /// one shortcut, not two controls beside each other.
    private static let capGap: CGFloat = 3

    public init(_ keys: String...) { self.init(keys) }
    public init(_ keys: [String]) { self.keys = keys }

    public var body: some View {
        HStack(spacing: Self.capGap) {
            ForEach(Array(keys.enumerated()), id: \.offset) { cap($0.element) }
        }
        // A restatement of a key equivalent, not a control: read out, it would turn every press of
        // the button into "Create Task command return".
        .accessibilityHidden(true)
    }

    static func ink(_ surface: Surface) -> Color { surface.ink }
    static func fill(_ surface: Surface) -> Color { surface.isOnAccent ? Palette.keycapFill : surface.badgeWash }
    static func stroke(_ surface: Surface) -> Color { surface.isOnAccent ? Palette.keycapStroke : Palette.border }

    private func cap(_ glyph: String) -> some View {
        Text(glyph)
            .foregroundStyle(Self.ink(surface))
            .frame(minWidth: Size.chip)
            .frame(height: Size.chip)
            .chipChrome(fill: Self.fill(surface), stroke: Self.stroke(surface))
            // Keep the cap native-sized and its stroke above the glyph. The outer font modifier
            // still reads the caller's scale, before this cap's geometry resets to standard.
            .interfaceScale(.standard)
            .font(Typography.mono)
    }
}
