import SwiftUI
import AiTermUI
import AiTermCore

/// Nuxt-UI style avatar group at the project tile's size: 18 px marks, 5 px overlap, a ring in the
/// row's own background colour so the circles read as stacked, and "+n" in the last slot once
/// there are more sessions than fit (design canvas, 17 Sep 2026). A task the Operator drives draws its
/// own agents too: the Operator speaks on the row's line (`OperatorBadge`), not here.
///
/// A task a signal started wears the signals disc on its first mark's corner (design decision 6, 25 Nov 2026), as a
/// badge wears its corner check: a `SymbolMark` of the signals glyph at `Size.cornerBadge`, overhanging the mark by
/// `Space.hairline`, ringed in the ground it sits on and drawn over the stack. The column keeps its width, and resting
/// on the disc (a `Size.chip` square centred on it) opens its signal card. With no agent of its listed, such a task draws
/// its agent's mark faded to `Opacity.disabled` (`AvatarGroup.muted`), so the disc rests on an avatar, not on nothing.
struct AvatarGroupView: View {
    /// How far each mark overlaps the one before it, so the group reads as a stack rather than a row.
    private static let overlap: CGFloat = -5
    /// The occluding ring every mark and the `+n` slot draw around themselves. A stroke, so it does not scale.
    static let ringWidth: CGFloat = 2
    /// The signals glyph (O6), as the section headings' signals icon draws it.
    static let signalGlyph = "dot.radiowaves.right"
    @Environment(\.interfaceScale) private var scale
    private var size: CGFloat { scale(markSize) }
    /// The group's fixed width: two stacked marks, which is all `SidebarModel.avatarMax` lets a row
    /// draw. A group with one mark still takes this width, so every row's title starts at the same x.
    static func columnWidth(_ scale: InterfaceScale) -> CGFloat { scale(Size.avatar) * 2 + scale(overlap) }
    let group: AvatarGroup
    /// Each mark's diameter before scaling: `Size.avatar` on a row; the background-work card's heading draws the group
    /// at `Size.vendorMark`, inside its `Size.chip` line, two marks wide at that size.
    var markSize: CGFloat = Size.avatar
    /// Whether the first mark wears the signals disc.
    var signalDisc = false
    /// Replaces the `ring: Color` this view used to take. The ring is painted *over* the avatar
    /// behind it, so it needs `Surface.occludingBackground` — an opaque colour — rather than a
    /// wash, which would let the stacked mark show through.
    @Environment(\.surface) private var surface
    var body: some View {
        HStack(spacing: scale(Self.overlap)) {
            ForEach(Array(group.marks.enumerated()), id: \.offset) { _, agent in
                VendorMark(agent: agent, size: size).opacity(group.muted ? Opacity.disabled : 1)
                    .overlay(Circle().stroke(surface.occludingBackground, lineWidth: Self.ringWidth))
            }
            if group.overflow > 0 {
                ZStack { Circle().fill(Palette.controlActive); Text("+\(group.overflow)").font(Typography.micro).foregroundStyle(Palette.text) }
                    .frame(width: size, height: size).overlay(Circle().stroke(surface.occludingBackground, lineWidth: Self.ringWidth))
            }
        }
        // Two marks at this group's own size: `columnWidth` on a row, narrower in the background-work card's heading.
        .frame(width: size * 2 + scale(Self.overlap), alignment: .leading)
        .overlay(alignment: .topLeading) {
            if signalDisc { disc }
        }
    }

    /// The disc's centre from the group's top-leading corner, on both axes: the first mark's bottom-trailing corner,
    /// less half the disc, plus the overhang.
    static func discCentre(_ scale: InterfaceScale) -> CGFloat {
        scale(Size.avatar) - scale(Size.cornerBadge) / 2 + scale(Space.hairline)
    }

    /// The disc in the middle of its hover square, placed on the first mark's corner.
    private var disc: some View {
        let offset = Self.discCentre(scale) - scale(Size.chip) / 2
        return SymbolMark(symbol: Self.signalGlyph, size: scale(Size.cornerBadge))
            .background { Circle().stroke(surface.occludingBackground, lineWidth: Self.ringWidth) }
            .opensSignalCard(square: scale(Size.chip))
            .offset(x: offset, y: offset)
    }
}
