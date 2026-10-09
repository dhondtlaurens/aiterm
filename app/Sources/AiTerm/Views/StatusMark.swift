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
    /// The one continuous animation in the app, so the one that has to answer Reduce Motion. The
    /// design canvas has honoured it since the first artboard; the app never did.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let spinDuration = 1.1

    /// The one spin every working mark shows, in degrees clockwise from three o'clock: a function
    /// of Core Animation's clock and nothing else, so an arc that starts later, comes back from a
    /// collapsed project or outlives a sleep shows the angle every other arc shows. Not the wall
    /// clock: `Date` runs on through a sleep and media time does not, which put every arc started
    /// after one on a phase of its own.
    static func spinnerRotation(atMediaTime time: CFTimeInterval) -> Double {
        time.truncatingRemainder(dividingBy: spinDuration) / spinDuration * 360
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
                    SpinnerArc(size: size, color: surface.isOnAccent ? Palette.onAccent : Palette.spinner)
                }
            case .needsInput:
                Circle().fill(Palette.amber)
            case .done:
                Circle().fill(Palette.done)
            }
        }.frame(width: size, height: size)
    }
}

/// The turning arc of a working mark, on the one spin they all share.
///
/// The turn is a Core Animation animation, not a SwiftUI one: each arc's starts a whole number of
/// turns before media time's zero, so the window server draws every arc at
/// `StatusMark.spinnerRotation(atMediaTime:)` — in step whenever it started, without a timer, and
/// without a `body` or the main thread doing anything per frame. A SwiftUI animation starts when
/// its transaction commits, which a busy main thread can put any number of degrees after the seed
/// it was given; there is no telling it to start in the past.
///
/// Snapshots draw the arc still, at the top right, as a SwiftUI shape: `ImageRenderer` cannot draw
/// an AppKit view.
private struct SpinnerArc: View {
    let size: CGFloat
    let color: Color
    #if DEBUG
    @Environment(\.stillSpinners) private var still
    #else
    private let still = false
    #endif

    var body: some View {
        if still {
            Circle().trim(from: 0, to: 0.15).stroke(color, style: StrokeStyle(lineWidth: size * 0.15, lineCap: .round))
                .rotationEffect(.degrees(300))
        } else {
            SpinningArc(size: size, color: color)
        }
    }
}

private struct SpinningArc: NSViewRepresentable {
    let size: CGFloat
    let color: Color

    func makeNSView(context: Context) -> SpinningArcView { SpinningArcView() }

    func updateNSView(_ view: SpinningArcView, context: Context) {
        #if DEBUG
        StatusMark.arcUpdates += 1
        #endif
        view.lineWidth = size * 0.15
        view.color = NSColor(color)
    }
}

/// Layer-hosting, so AppKit leaves its layers to it: the arc is a shape layer turning about the
/// view's centre. It passes every click through to its row.
final class SpinningArcView: NSView {
    static let spinKey = "spin"
    let arc = CAShapeLayer()
    var lineWidth: CGFloat = 0 { didSet { if lineWidth != oldValue { needsLayout = true } } }
    var color = NSColor.clear { didSet { if color != oldValue { paint() } } }

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        arc.fillColor = nil
        arc.lineCap = .round
        arc.strokeEnd = 0.15
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
        turn.duration = StatusMark.spinDuration
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        let now = CACurrentMediaTime()
        turn.beginTime = arc.convertTime(now, from: nil) - now.truncatingRemainder(dividingBy: StatusMark.spinDuration)
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
