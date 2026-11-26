import AppKit
import Testing
import AiTermUI
@testable import AiTermCore
@testable import AiTerm

/// The status line's segment: where its strokes stop, and that its dots are placed by its y in the list's document
/// so they line up across rows, marching only while motion is allowed.
@MainActor
struct StatusLineViewTests {
    private final class Document: NSView { override var isFlipped: Bool { true } }

    /// A segment in a scroll view's document, `y` down it.
    private func segment(at y: CGFloat, still: Bool) -> StatusLineView {
        let document = Document(frame: CGRect(x: 0, y: 0, width: 40, height: 600))
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 40, height: 300))
        scroll.documentView = document
        let view = StatusLineView()
        view.frame = CGRect(x: 10, y: y, width: 20, height: 60)
        document.addSubview(view)
        view.lineWidth = 1.5
        view.dash = [Space.hairline, Space.tight]
        view.still = still
        view.strokes = [StatusLineView.Stroke(from: 0, to: 21, color: .textColor, dotted: true, marchesDown: true),
                        StatusLineView.Stroke(from: 39, to: 60, color: .textColor, dotted: true, marchesDown: true)]
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Each stroke's dash starts at its top's y in the document modulo one dot and gap, wherever the row lies, and a
    /// still segment adds no animation.
    @Test(arguments: [0, 13, 52.5, 371])
    func aStillSegmentsDashPhaseFollowsItsY(y: CGFloat) {
        let view = segment(at: y, still: true)
        let period = Space.hairline + Space.tight
        #expect(view.documentTop == y)
        #expect(view.shapes.count == 2)
        #expect(abs(view.shapes[0].lineDashPhase - StatusLineStroke.phase(top: y, period: period)) < 0.001)
        #expect(abs(view.shapes[1].lineDashPhase - StatusLineStroke.phase(top: y + 39, period: period)) < 0.001)
        #expect(view.shapes.allSatisfy { $0.animation(forKey: StatusLineView.marchKey) == nil }, "Reduce Motion: the dots stand still")
    }

    /// Moving, each dotted stroke marches its phase one period down, in a quarter second at `Motion.march`, from where
    /// its y puts it; up for a wake.
    @Test func aMovingSegmentMarchesFromItsPhase() throws {
        let view = segment(at: 13, still: false)
        let march = try #require(view.shapes[0].animation(forKey: StatusLineView.marchKey) as? CABasicAnimation)
        let from = try #require(march.fromValue as? CGFloat), to = try #require(march.toValue as? CGFloat)
        #expect(from == view.shapes[0].lineDashPhase && to == from - (Space.hairline + Space.tight))
        #expect(abs(march.duration - 0.25) < 0.0001 && march.repeatCount == .infinity)
        view.strokes = view.strokes.map { var stroke = $0; stroke.marchesDown = false; return stroke }
        view.layoutSubtreeIfNeeded()
        let up = try #require(view.shapes[0].animation(forKey: StatusLineView.marchKey) as? CABasicAnimation)
        #expect((up.toValue as? CGFloat) == from + (Space.hairline + Space.tight))
        view.still = true
        view.layoutSubtreeIfNeeded()
        #expect(view.shapes[0].animation(forKey: StatusLineView.marchKey) == nil)
    }

    /// A stroke stops `Space.base` short of a mark's centre (its round end included), 3 pt clear of the 10 pt ring, and
    /// `Size.statusStop` short of a stop's; through a row with nothing at its centre it is one stroke, edge to edge;
    /// at each interface size.
    @Test(arguments: InterfaceScale.all)
    func strokesStopShortOfMarksAndStops(scale: InterfaceScale) throws {
        let height: CGFloat = 60, width = StatusLineSegment.lineWidth(scale)
        let mark = StatusLineSegment.strokes(StatusLinePiece(above: .rest, below: .acting, node: .mark), height: height, scale: scale)
        #expect(mark.map(\.from) == [0, height / 2 + scale(Space.base) + width / 2])
        #expect(mark.map(\.to) == [height / 2 - scale(Space.base) - width / 2, height])
        #expect(scale(Space.base) - scale(Size.trailingGlyph) / 2 >= 3, "3 pt clear of the ring")
        let stop = StatusLineSegment.strokes(StatusLinePiece(above: .asking, node: .stop(.asking)), height: height, scale: scale)
        #expect(stop == [StatusLineStroke(from: 0, to: height / 2 - scale(Size.statusStop) - width / 2, ink: .asking)])
        let through = StatusLineSegment.strokes(StatusLinePiece(above: .rest, below: .rest), height: height, scale: scale)
        #expect(through == [StatusLineStroke(from: 0, to: height, ink: .rest)])
        #expect(StatusLineSegment.strokes(StatusLinePiece(above: .rest, node: .mark), height: height, scale: scale).count == 1,
                "the end of the line has nothing below its mark")
    }
}
