import SwiftUI

/// The one 1 pt rule: by default the soft `Palette.border`, the same stroke as a card's edge. The
/// sidebar's rules (either side of a `DividerRow`'s name, the sidebar footer's scroll edge) and a
/// sheet's section breaks — its header's and footer's edges, under a Settings card's header, between
/// the Interface tab's rows — all draw it. `.firm` draws the firm `Palette.borderStrong` a field is
/// outlined in, for a short rule that has to hold on its own: the connectors between a sheet's steps.
///
/// A rectangle, not SwiftUI's `Divider`, so it stays horizontal inside an `HStack`, where `Divider`
/// turns vertical. The sheets used to lay `Divider` under the border, which read a third brighter
/// than this; that second weight was folded into this one. A stroke, so it does not scale.
public struct Hairline: View {
    /// Which of the two hairline inks it draws.
    public enum Weight: Sendable { case soft, firm }

    let weight: Weight

    public init(_ weight: Weight = .soft) { self.weight = weight }

    public var body: some View {
        Rectangle().fill(weight == .firm ? Palette.borderStrong : Palette.border).frame(height: 1)
    }
}
