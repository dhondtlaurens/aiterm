import SwiftUI
import AiTermUI
import AiTermCore

struct StatusMark: View {
    let status: TaskStatus
    /// The mark's diameter in points: a row passes its trailing column's glyph,
    /// `scale(Size.trailingGlyph)` (which `Size.statusMark` aliases); the collapsed project header's
    /// count chips pass `scale(Size.statusMarkSmall)`. Every measurement below is a fraction of it,
    /// and at 10 they are the values this view was written with.
    let size: CGFloat
    /// Replaces the `onSelection: Bool` this view used to take: a selected row's surface is
    /// `.accent`, and `isOnAccent` is exactly the condition the mark used to be handed directly.
    @Environment(\.surface) private var surface
    /// The one continuous animation in the app, so the one that has to answer Reduce Motion. The
    /// design canvas has honoured it since the first artboard; the app never did.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let spinDuration = 1.1

    /// Derive rotation from a shared clock instead of view lifetime. A row can disappear when its
    /// project collapses, or briefly leave `.working` when an agent reports done before resuming.
    /// Returning at the clock's current phase keeps the arc continuous in both cases.
    static func spinnerRotation(at date: Date) -> Double {
        let elapsed = date.timeIntervalSinceReferenceDate
        return elapsed.truncatingRemainder(dividingBy: spinDuration) / spinDuration * 360
    }

    var body: some View {
        ZStack {
            switch status {
            case .idle: Circle().strokeBorder(Palette.idleRing, lineWidth: size * 0.15)
            case .working:
                Circle().trim(from: 0.15, to: 1).stroke(surface.isOnAccent ? Palette.spinnerTrackOnAccent : Palette.spinnerTrack, style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
                // Reduce Motion keeps the shape and drops the rotation: a still three-quarter arc
                // still reads as "not idle, not waiting", which is the whole job of this mark.
                if reduceMotion {
                    Circle().trim(from: 0, to: 0.5).stroke(surface.isOnAccent ? Palette.onAccent : Palette.spinner, style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
                } else {
                    // 30 fps rather than the display's rate: the sidebar is always on screen, one
                    // timeline runs per working row, and a 10 pt arc turning once a second gains
                    // nothing visible from more frames.
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        Circle().trim(from: 0, to: 0.15).stroke(surface.isOnAccent ? Palette.onAccent : Palette.spinner, style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
                            .rotationEffect(.degrees(Self.spinnerRotation(at: context.date)))
                    }
                }
            case .needsInput:
                Circle().fill(Palette.amber)
            case .done:
                Circle().fill(Palette.done)
            }
        }.frame(width: size, height: size)
    }
}
