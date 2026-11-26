import AppKit
import SwiftUI
import AiTermUI
import AiTermCore

/// One row's part of the Operator's status line (decision 7): a line down the trailing slot from the row's top edge to
/// its bottom edge, stopping `Space.base` short of a status mark's centre (3 pt clear of the ring) and
/// `Size.statusStop` short of a stop's, which it draws filled at `Size.statusStop` across. The row's neighbour paints
/// the rest: the list's 8 pt gap between two rows is theirs half each, and nothing here draws into another row
/// (`StatusLineSeamTests`).
///
/// The stroke is `RingGeometry`'s for the row's trailing glyph, with round ends. At rest it is `Palette.statusLine`,
/// solid; an exchange dots its stretch in `Palette.text` (`Space.hairline` on, `Space.tight` off) and marches it down
/// while the Operator acts and up for a wake; a question holds it `Palette.amber`, solid and still. Only the text ink
/// moves. The march is Core Animation's, anchored to media time as the status mark's spin is, and each stroke's dash
/// starts at its top's y in the list's document, so the dots of every row line up and march in step, without a
/// `body` per frame. Under Reduce Motion they stand still; a snapshot draws them still as a SwiftUI stroke, since
/// `ImageRenderer` cannot draw a layer.
struct StatusLineSegment: View {
    let piece: StatusLinePiece
    @Environment(\.interfaceScale) private var scale
    @Environment(\.motionStill) private var motionStill

    /// What the segment strokes, in its own top-down points, for a segment `height` tall.
    static func strokes(_ piece: StatusLinePiece, height: CGFloat, scale: InterfaceScale) -> [StatusLineStroke] {
        let width = lineWidth(scale), centre = height / 2
        let gap: CGFloat
        switch piece.node {
        case .none: gap = 0
        case .mark: gap = scale(Space.base)
        case .stop: gap = scale(Size.statusStop)
        }
        // A round end reaches half the stroke past its point, so a stroke stopping short of a node ends there.
        let end = gap > 0 ? gap + width / 2 : 0
        if piece.node == .none, let above = piece.above, above == piece.below {
            return [StatusLineStroke(from: 0, to: height, ink: above)]
        }
        return [piece.above.map { StatusLineStroke(from: 0, to: centre - end, ink: $0) },
                piece.below.map { StatusLineStroke(from: centre + end, to: height, ink: $0) }]
            .compactMap { $0 }.filter { $0.to > $0.from }
    }

    static func lineWidth(_ scale: InterfaceScale) -> CGFloat { RingGeometry.strokeWidth(scale(Size.trailingGlyph)) }
    /// A dotted stroke's dot and gap.
    static func dash(_ scale: InterfaceScale) -> [CGFloat] { [scale(Space.hairline), scale(Space.tight)] }

    static func color(_ ink: StatusLineInk) -> Color {
        switch ink {
        case .rest: Palette.statusLine
        case .acting, .waking: Palette.text
        case .asking: Palette.amber
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let strokes = Self.strokes(piece, height: proxy.size.height, scale: scale)
            ZStack {
                if motionStill == .snapshot {
                    StillStatusLine(strokes: strokes, width: Self.lineWidth(scale), dash: Self.dash(scale))
                } else {
                    StatusLineStrokes(strokes: strokes, lineWidth: Self.lineWidth(scale), dash: Self.dash(scale),
                                      still: motionStill != nil)
                }
                if case .stop(let ink) = piece.node {
                    Circle().fill(Self.color(ink)).frame(width: scale(Size.statusStop), height: scale(Size.statusStop))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One stroke of a segment, in the segment's top-down points.
struct StatusLineStroke: Equatable {
    var from: CGFloat
    var to: CGFloat
    var ink: StatusLineInk

    var dotted: Bool { ink == .acting || ink == .waking }
    /// Which way its dots march: down while the Operator acts, up for a wake.
    var marchesDown: Bool? {
        switch ink {
        case .acting: true
        case .waking: false
        case .rest, .asking: nil
        }
    }

    /// Where along its dash a stroke whose top lies `top` down the list's document starts, so that every stroke's
    /// dots fall on the same document rows whichever row draws them.
    static func phase(top: CGFloat, period: CGFloat) -> CGFloat {
        guard period > 0 else { return 0 }
        let phase = top.truncatingRemainder(dividingBy: period)
        return phase < 0 ? phase + period : phase
    }
}

/// The snapshot's still line, as a SwiftUI stroke, its dots placed by the segment's y in the image.
private struct StillStatusLine: View {
    let strokes: [StatusLineStroke]
    let width: CGFloat
    let dash: [CGFloat]

    var body: some View {
        GeometryReader { proxy in
            let top = proxy.frame(in: .global).minY, midX = proxy.size.width / 2
            ForEach(Array(strokes.enumerated()), id: \.offset) { _, stroke in
                Path { path in
                    path.move(to: CGPoint(x: midX, y: stroke.from))
                    path.addLine(to: CGPoint(x: midX, y: stroke.to))
                }
                .stroke(StatusLineSegment.color(stroke.ink),
                        style: StrokeStyle(lineWidth: width, lineCap: .round, dash: stroke.dotted ? dash : [],
                                           dashPhase: StatusLineStroke.phase(top: top + stroke.from, period: dash.reduce(0, +))))
            }
        }
    }
}

private struct StatusLineStrokes: NSViewRepresentable {
    let strokes: [StatusLineStroke]
    let lineWidth: CGFloat
    let dash: [CGFloat]
    let still: Bool

    func makeNSView(context: Context) -> StatusLineView { StatusLineView() }

    func updateNSView(_ view: StatusLineView, context: Context) {
        view.lineWidth = lineWidth
        view.dash = dash
        view.still = still
        view.strokes = strokes.map {
            StatusLineView.Stroke(from: $0.from, to: $0.to, color: NSColor(StatusLineSegment.color($0.ink)),
                                  dotted: $0.dotted, marchesDown: $0.marchesDown)
        }
    }
}

/// Layer-hosting, so AppKit leaves its layers to it: one shape layer per stroke. It passes every click through to its
/// row. Its strokes' dashes start at their top's y in the enclosing scroll view's document (the list's), which it
/// works out again whenever its row moves there; a marching stroke's dash phase runs one dot and gap a period, from a
/// media-time start every stroke shares.
final class StatusLineView: NSView {
    struct Stroke: Equatable {
        /// Its ends, in the view's top-down points.
        var from: CGFloat, to: CGFloat
        var color: NSColor
        var dotted: Bool
        /// Down, up, or still.
        var marchesDown: Bool?
    }
    static let marchKey = "march"
    var strokes: [Stroke] = [] { didSet { if strokes != oldValue { needsLayout = true } } }
    var lineWidth: CGFloat = 0 { didSet { if lineWidth != oldValue { needsLayout = true } } }
    var dash: [CGFloat] = [] { didSet { if dash != oldValue { needsLayout = true } } }
    /// Reduce Motion: the dots stand still where they are.
    var still = false { didSet { if still != oldValue { needsLayout = true } } }
    /// The view's top, down the enclosing scroll view's document, as last worked out.
    private(set) var documentTop: CGFloat = 0
    private(set) var shapes: [CAShapeLayer] = []
    private var rowMoves: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        if let rowMoves { NotificationCenter.default.removeObserver(rowMoves) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var period: CGFloat { dash.reduce(0, +) }

    /// The view's top down the document of the scroll view it sits in (the list's), else its window's content.
    func workOutDocumentTop() -> CGFloat {
        guard let reference = enclosingScrollView?.documentView ?? window?.contentView else { return 0 }
        let rect = convert(bounds, to: reference)
        return reference.isFlipped ? rect.minY : reference.bounds.height - rect.maxY
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watchRow()
        needsLayout = true
    }

    /// A row moving in the list (one inserted above it, or the row view reused for another row) moves this view in the
    /// document without changing its frame in the row: the row view's frame says so.
    private func watchRow() {
        if let rowMoves { NotificationCenter.default.removeObserver(rowMoves) }
        rowMoves = nil
        var ancestor = superview
        while let view = ancestor, !(view is NSTableRowView) { ancestor = view.superview }
        guard let row = ancestor else { return }
        row.postsFrameChangedNotifications = true
        rowMoves = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: row, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsLayout = true }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        documentTop = workOutDocumentTop()
        unanimated {
            while shapes.count < strokes.count {
                let shape = CAShapeLayer()
                shape.fillColor = nil
                shape.lineCap = .round
                layer?.addSublayer(shape)
                shapes.append(shape)
            }
            while shapes.count > strokes.count { shapes.removeLast().removeFromSuperlayer() }
            for (shape, stroke) in zip(shapes, strokes) {
                shape.frame = bounds
                shape.lineWidth = lineWidth
                // Top-down ends in the layer's unflipped space.
                let path = CGMutablePath()
                path.move(to: CGPoint(x: bounds.midX, y: bounds.height - stroke.from))
                path.addLine(to: CGPoint(x: bounds.midX, y: bounds.height - stroke.to))
                shape.path = path
                effectiveAppearance.performAsCurrentDrawingAppearance { shape.strokeColor = stroke.color.cgColor }
                shape.lineDashPattern = stroke.dotted ? dash.map { NSNumber(value: Double($0)) } : nil
                shape.lineDashPhase = StatusLineStroke.phase(top: documentTop + stroke.from, period: period)
            }
        }
        for (shape, stroke) in zip(shapes, strokes) { march(shape, stroke) }
    }

    /// Marches a dotted stroke's dash phase one period down or up, over and over, from a start a whole number of
    /// periods before media time's zero: every stroke is in step whenever it began, and one added again lands on the
    /// same phase.
    private func march(_ shape: CAShapeLayer, _ stroke: Stroke) {
        guard stroke.dotted, let down = stroke.marchesDown, !still, period > 0 else {
            shape.removeAnimation(forKey: Self.marchKey)
            return
        }
        let from = shape.lineDashPhase, to = down ? from - period : from + period
        if let running = shape.animation(forKey: Self.marchKey) as? CABasicAnimation,
           (running.fromValue as? CGFloat) == from, (running.toValue as? CGFloat) == to { return }
        let march = CABasicAnimation(keyPath: "lineDashPhase")
        march.fromValue = from
        march.toValue = to
        march.duration = Double(period / Motion.march)
        march.repeatCount = .infinity
        march.isRemovedOnCompletion = false
        let now = CACurrentMediaTime()
        march.beginTime = shape.convertTime(now, from: nil) - now.truncatingRemainder(dividingBy: march.duration)
        shape.add(march, forKey: Self.marchKey)
    }

    private func unanimated(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}

/// A row's piece of the status line, read from its own cell (`SidebarProjection.statusLine`), so a piece changing
/// redraws this and not the row.
struct StatusLineCell: View {
    let id: UUID
    let rows: SidebarProjection
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.countLine(id)
        #endif
        if let piece = rows.statusLine[id] { StatusLineSegment(piece: piece) }
    }
}

/// A row's piece of the status line behind its trailing slot (`trailing` in from the view's trailing edge), reaching
/// `reach` above and below the view, to its row's edges: over the pill's fill, under the row's content. Nothing
/// without `rows`.
struct StatusLineOverlay: ViewModifier {
    let id: UUID
    let rows: SidebarProjection?
    let reach: CGFloat
    var trailing: CGFloat = 0
    @Environment(\.interfaceScale) private var scale

    func body(content: Content) -> some View {
        content.background(alignment: .trailing) {
            if let rows {
                StatusLineCell(id: id, rows: rows)
                    .frame(width: SidebarRowLayout.trailingSlot(scale))
                    .padding(.vertical, -reach)
                    .padding(.trailing, trailing)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// How far a row's status line reaches past the row's drawn box: half the list's gap between two rows, which does not
/// scale (`StatusLineSeamTests`). The neighbour reaches the other half.
enum StatusLineReach {
    static let halfGap = Space.tight
}
