import SwiftUI
import AiTermCore
import AiTermUI

/// The round vendor avatar used in the sidebar's avatar group and in the agent picker.
struct VendorMark: View {
    let agent: SessionAgent
    let size: CGFloat
    /// The gap between the shell glyph's chevron and its underscore — unlike every other
    /// measurement in this glyph, not a fraction of `size`: at any size this small a proportional
    /// gap either touches or floats free, so it stays a fixed 1 pt.
    private static let promptGap: CGFloat = 1
    /// The underscore's own stroke weight — fixed for the same reason as `promptGap`: a fraction of
    /// `size` would vanish to sub-pixel at the smallest mark this glyph is drawn at.
    private static let underscoreWeight: CGFloat = 1.5
    var body: some View {
        ZStack {
            switch agent {
            case .claude:
                Circle().fill(Palette.claude.color)
                Icon(.brand(Palette.claude), size: size * LogoFit.standard.scale, tint: Palette.markPaper)
            case .codex:
                Circle().fill(Palette.markPaper)
                Icon(.brand(Palette.openai), size: size * LogoFit.standard.scale)
            case .pi:
                Circle().fill(Palette.markInk)
                Icon(.piBadge, size: size * LogoFit.pi.scale, tint: Palette.markPaper)
                    .offset(x: size * LogoFit.pi.dx, y: size * LogoFit.pi.dy)
            case .shell:
                Circle().fill(Palette.markInk)
                // The `>_` prompt glyph from the canvas: a bold chevron and a short underscore.
                HStack(alignment: .bottom, spacing: Self.promptGap) {
                    Image(systemName: "chevron.right").font(.system(size: size * 0.36, weight: .bold)).foregroundStyle(Palette.markPaper)
                    Rectangle().fill(Palette.markPaper).frame(width: size * 0.2, height: Self.underscoreWeight).padding(.bottom, size * 0.08)
                }
            }
        }.frame(width: size, height: size)
    }
}

/// How a logo sits in its disc. The recipe draws a logo in a box `scale` of the disc's diameter,
/// but logos do not carry equal ink in equal boxes: Claude, OpenAI and the tanuki each cover about
/// 18% of the disc at 61%, while PI's solid square covers 30% and Jira's three filled chevrons 23%,
/// and both of those lean off-centre. Each gets the box that brings its ink to the family's 18% and
/// an offset — a fraction of the diameter — that puts its centre of mass on the disc's centre,
/// *unless* a mark's own shape would reach past the disc's edge first: nothing here clips to the
/// circle, so a box scaled past that point paints outside it, on the plain ground behind the disc.
/// Containment always wins over the ink target. Measured on the `marks.png` snapshot; re-measure
/// there before changing one, checking both the ink/centroid and that no glyph pixel lands outside
/// the disc's radius.
struct LogoFit {
    let scale: CGFloat
    var dx: CGFloat = 0
    var dy: CGFloat = 0

    static let standard = LogoFit(scale: 0.61)
    /// The square's mass sits in its left leg.
    static let pi = LogoFit(scale: 0.48, dx: 0.036)
    /// The chevrons climb to the top right.
    static let jira = LogoFit(scale: 0.55, dx: -0.04, dy: 0.04)
}
