import SwiftUI

/// A settled mark: a filled disc for a state that holds until something outside changes it, where a ring
/// (`StatusMark` in the app) is a state that can still move. `finished` is the `Palette.green` disc with a white
/// check, the mark a done ticket's badge, or an approved request's with every thread resolved, wears in its corner
/// (`Badge(corner:)`).
/// `paused` is the `Palette.idleRing` disc with its two bars cut out in the ground beneath
/// (`Surface.occludingBackground`).
/// On the accent, as everything there, the disc turns `onAccent` and its glyph is cut out of it.
///
/// Drawn shapes, not SF Symbols, in proportions of `size`, so the badge's corner, a row's trailing column and a
/// count chip draw one shape at three sizes.
public struct SettledMark: View {
    public enum Kind: Equatable, Sendable { case finished, paused }

    let kind: Kind
    let size: CGFloat
    @Environment(\.surface) private var surface

    public init(_ kind: Kind, size: CGFloat) {
        self.kind = kind
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle().fill(Self.disc(kind, surface: surface))
            switch kind {
            case .finished:
                CheckGlyph().stroke(Self.glyph(kind, surface: surface),
                                    style: StrokeStyle(lineWidth: CheckGlyph.strokeWidth(size), lineCap: .round, lineJoin: .round))
            case .paused:
                PauseGlyph().fill(Self.glyph(kind, surface: surface))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// The disc's colour: green or the idle ring's grey, white on the accent.
    static func disc(_ kind: Kind, surface: Surface) -> Color {
        if surface.isOnAccent { return Palette.onAccent }
        switch kind {
        case .finished: return Palette.green
        case .paused: return Palette.idleRing
        }
    }

    /// The glyph's: the check is white on its green disc, the pause bars the ground's; on the
    /// accent every glyph is the ground's, cut out of the white disc.
    static func glyph(_ kind: Kind, surface: Surface) -> Color {
        kind != .paused && !surface.isOnAccent ? Palette.onAccent : surface.occludingBackground
    }
}

/// A check's two strokes, in proportions of its box, inset so the round caps stay inside the disc.
struct CheckGlyph: Shape {
    /// A sixth of the disc: thin enough to leave the disc's colour around it at `Size.cornerBadge`.
    static func strokeWidth(_ diameter: CGFloat) -> CGFloat { diameter / 6 }

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y) }
        var path = Path()
        path.move(to: point(0.27, 0.52))
        path.addLine(to: point(0.44, 0.69))
        path.addLine(to: point(0.74, 0.34))
        return path
    }
}

/// The pause sign's two bars, in proportions of the disc, centred and rounded at their ends.
struct PauseGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in [0.31, 0.56] {
            let bar = CGRect(x: rect.minX + rect.width * x, y: rect.minY + rect.height * 0.29,
                             width: rect.width * 0.13, height: rect.height * 0.42)
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: bar.width * 0.3, height: bar.width * 0.3))
        }
        return path
    }
}
