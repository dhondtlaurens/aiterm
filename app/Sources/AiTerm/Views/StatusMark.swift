import AppKit
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
    @Environment(\.motionStill) private var motionStill
    static let spinDuration = 1.1
    /// A background mark's turn: slow enough to read as waiting rather than working.
    static let backgroundSpinDuration = 6.0
    /// The dashes a background mark's ring is cut into, each a little longer than the gap after it.
    static let backgroundDashes = 8
    static let backgroundDashShare = 0.57

    /// A background ring's dash and gap, in points, for a ring of `radius`: `backgroundDashes` of them around it.
    static func backgroundDash(radius: CGFloat) -> [CGFloat] {
        let each = 2 * .pi * radius / CGFloat(backgroundDashes)
        return [each * backgroundDashShare, each * (1 - backgroundDashShare)]
    }

    var body: some View {
        // Every look is a ring of the same stroke inside the same box, `size` across (proposal 1A
        // and 2A, 21 Oct 2026): `strokeBorder` insets by half its width, and the arc, which
        // `trim` makes a `stroke`, is padded by the same half so it no longer reaches past the
        // box the idle ring, the track and the footer's `UsageRing` sit in.
        ZStack {
            switch status {
            case .idle: Circle().strokeBorder(Palette.idleRing, lineWidth: size * 0.15)
            case .working:
                // The whole track: a trim that left out the arc's resting slice showed that slice
                // as a gap at four o'clock once the arc turned away from it.
                Circle().strokeBorder(surface.isOnAccent ? Palette.spinnerTrackOnAccent : Palette.spinnerTrack, lineWidth: size * 0.15)
                ZStack {
                    // Preserve Reduce Motion's half-circle; the snapshot pose below is a shorter arc.
                    if motionStill == .reduceMotion {
                        Circle().trim(from: 0, to: 0.5).stroke(surface.isOnAccent ? Palette.onAccent : Palette.spinner, style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
                    } else {
                        SpinnerArc(size: size, color: surface.isOnAccent ? Palette.onAccent : Palette.spinner)
                    }
                }
                .padding(size * 0.15 / 2)
            // Amber stays amber on the accent: it reads there, and it is the one being asked for.
            case .needsInput:
                Circle().strokeBorder(Palette.amber, lineWidth: size * 0.15)
            // A turn ended with work still running, which wakes the agent again (proposal Background work on your own
            // tasks B): the ring dashed, turning slowly, in the arc's ink. Reduce Motion keeps it still.
            case .background:
                ZStack {
                    if motionStill == .reduceMotion {
                        DashedRing(size: size, color: surface.isOnAccent ? Palette.onAccent : Palette.spinner)
                    } else {
                        SpinnerArc(size: size, color: surface.isOnAccent ? Palette.onAccent : Palette.spinner, style: .dashed)
                    }
                }
                .padding(size * 0.15 / 2)
            // The accent on the accent is blue on blue, so a selected row's done ring is white, as
            // its arc is.
            case .done:
                Circle().strokeBorder(surface.isOnAccent ? Palette.onAccent : Palette.done, lineWidth: size * 0.15)
            }
        }.frame(width: size, height: size)
    }
}

/// The turning arc of a working mark, on the one spin they all share.
///
/// The turn is a Core Animation animation, not a SwiftUI one: each arc's starts a whole number of
/// turns before media time's zero, so the window server draws every arc at
/// Core Animation’s media clock — in step whenever it started, without a timer, and
/// without a `body` or the main thread doing anything per frame. A SwiftUI animation starts when
/// its transaction commits, which a busy main thread can put any number of degrees after the seed
/// it was given; there is no telling it to start in the past.
///
/// Snapshots draw the arc still, at the top right, as a SwiftUI shape: `ImageRenderer` cannot draw
/// an AppKit view.
private struct SpinnerArc: View {
    let size: CGFloat
    let color: Color
    var style = SpinningArcView.Style.arc
    @Environment(\.motionStill) private var motionStill

    var body: some View {
        if motionStill == .snapshot {
            switch style {
            case .arc:
                Circle().trim(from: 0, to: 0.15).stroke(color, style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
                    .rotationEffect(.degrees(300))
            case .dashed: DashedRing(size: size, color: color)
            }
        } else {
            SpinningArc(size: size, color: color, style: style)
        }
    }
}

/// A background mark's ring held still: under Reduce Motion, and in snapshots.
private struct DashedRing: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        // Inside the mark's half-stroke padding, so the path's radius is the padded box's.
        let radius = size / 2 - size * 0.15 / 2
        Circle().stroke(color, style: StrokeStyle(lineWidth: size * 0.15, dash: StatusMark.backgroundDash(radius: radius)))
    }
}

private struct SpinningArc: NSViewRepresentable {
    let size: CGFloat
    let color: Color
    let style: SpinningArcView.Style

    func makeNSView(context: Context) -> SpinningArcView { SpinningArcView(style: style) }

    func updateNSView(_ view: SpinningArcView, context: Context) {
        #if DEBUG
        StatusMark.arcUpdates += 1
        #endif
        view.lineWidth = size * 0.15
        view.color = NSColor(color)
    }
}

/// Layer-hosting, so AppKit leaves its layers to it: the arc is a shape layer turning about the
/// view's centre. It passes every click through to its row. A `dashed` one is a background mark's ring:
/// the whole circle in dashes, on its own slower turn.
final class SpinningArcView: NSView {
    enum Style { case arc, dashed }
    static let spinKey = "spin"
    let arc = CAShapeLayer()
    let style: Style
    var lineWidth: CGFloat = 0 { didSet { if lineWidth != oldValue { needsLayout = true } } }
    var color = NSColor.clear { didSet { if color != oldValue { paint() } } }
    private var duration: Double { style == .arc ? StatusMark.spinDuration : StatusMark.backgroundSpinDuration }

    init(style: Style = .arc) {
        self.style = style
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        arc.fillColor = nil
        arc.lineCap = style == .arc ? .round : .butt
        arc.strokeEnd = style == .arc ? 0.15 : 1
        layer?.addSublayer(arc)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        unanimated {
            arc.frame = bounds
            arc.lineWidth = lineWidth
            // Clockwise from three o'clock on screen, which is a falling angle in a layer's
            // unflipped space: the path `Circle().trim(from: 0, to: 0.15)` strokes.
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2,
                        startAngle: 0, endAngle: -2 * .pi, clockwise: true)
            arc.path = path
            if style == .dashed {
                arc.lineDashPattern = StatusMark.backgroundDash(radius: bounds.width / 2).map { NSNumber(value: Double($0)) }
            }
        }
        spin()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        spin()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        unanimated { effectiveAppearance.performAsCurrentDrawingAppearance { arc.strokeColor = color.cgColor } }
    }

    /// Starts the turn if the arc has none: once added it runs for as long as the layer lives, and
    /// one added again later lands on the same phase.
    private func spin() {
        guard arc.animation(forKey: Self.spinKey) == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = duration
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        let now = CACurrentMediaTime()
        turn.beginTime = arc.convertTime(now, from: nil) - now.truncatingRemainder(dividingBy: duration)
        arc.add(turn, forKey: Self.spinKey)
    }

    private func unanimated(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}

#if DEBUG
extension StatusMark {
    /// How many times a spinning arc's view has been updated, which a test reads to show that the
    /// turn is Core Animation's rather than an update per frame. Debug builds only.
    @MainActor static var arcUpdates = 0
}
#endif
