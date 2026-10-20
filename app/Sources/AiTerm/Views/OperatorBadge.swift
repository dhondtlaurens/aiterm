import AppKit
import SwiftUI
import AiTermUI
import AiTermCore

/// Everything the Operator says on a status line (spec §7, §13, §14): the words of an `OperatorLine` in
/// `Typography.monoChip`, no mark: where the line sits says whose it is. Always one `Size.chip` line: the
/// words cut with an ellipsis rather than wrap, the whole of them in the tooltip and VoiceOver's label. The
/// last line of a driven task's row and of the broadcast row, a card's last line on the board, the band
/// under the board's title.
///
/// It reads its ground (`Surface`), as `RowCaption(warns:)` does:
/// - quiet, and ended: no box, the words in the surface's secondary ink (an ended row's check is its
///   trailing mark's, `TaskRowMark`, never the line's);
/// - acting: no box, the words shimmering, a light band sweeping from the surface's secondary ink through
///   its ink every `shimmerPeriod` on Core Animation's clock (`ShimmerWordsView`), nothing updated per
///   frame; standing still in the surface's ink under Reduce Motion and in the snapshots;
/// - needs you: the attention chip's pair (`Palette.statusChipAttentionFill` and `Stroke`) with the words
///   in `Palette.text`, never amber; on `Surface.accent` the surface's `badgeWash` and ink, the amber left
///   to the row's `StatusMark`, since an amber wash on the selection's blue reads as mud.
struct OperatorBadge: View {
    let line: OperatorLine
    @Environment(\.surface) private var surface
    @Environment(\.interfaceScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @Environment(\.stillSpinners) private var still
    #else
    private let still = false
    #endif

    /// One sweep of the shimmer, in seconds: about 1.6 s, as picked (19 Oct 2026).
    static let shimmerPeriod = 1.6

    /// The box a look draws, when it draws one.
    struct Box: Equatable { var fill: Color; var stroke: Color? }

    /// Whether the words move: only while acting, never under Reduce Motion, never in a snapshot.
    static func shimmers(_ look: OperatorLine.Look, reduceMotion: Bool, still: Bool) -> Bool {
        look == .acting && !reduceMotion && !still
    }

    /// The words' ink. Shimmering, the band of the surface's ink sweeps over the secondary ink.
    static func ink(_ look: OperatorLine.Look, surface: Surface, shimmering: Bool) -> Color {
        switch look {
        case .quiet, .ended: surface.secondaryInk
        case .acting: shimmering ? surface.secondaryInk : surface.ink
        case .needsYou: surface.isOnAccent ? surface.ink : Palette.text
        }
    }

    /// Only needs-you has a box: the attention chip's fill and edge, or on the accent its wash alone.
    static func box(_ look: OperatorLine.Look, surface: Surface) -> Box? {
        guard look == .needsYou else { return nil }
        return surface.isOnAccent ? Box(fill: surface.badgeWash, stroke: nil)
            : Box(fill: Palette.statusChipAttentionFill, stroke: Palette.statusChipAttentionStroke)
    }

    var body: some View {
        let shimmering = Self.shimmers(line.look, reduceMotion: reduceMotion, still: still)
        let box = Self.box(line.look, surface: surface)
        words(shimmering: shimmering)
            .padding(.horizontal, box == nil ? 0 : scale(Space.tight))
            .frame(height: scale(Size.chip))
            .background {
                if let box {
                    RoundedRectangle(cornerRadius: scale(Radius.chip)).fill(box.fill)
                        .overlay { if let stroke = box.stroke { RoundedRectangle(cornerRadius: scale(Radius.chip)).strokeBorder(stroke) } }
                }
            }
            .help(line.tooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.tooltip)
    }

    @ViewBuilder
    private func words(shimmering: Bool) -> some View {
        let text = Text(line.text).font(Typography.monoChip).lineLimit(1).truncationMode(.tail)
        if shimmering {
            // Laid out by the text, drawn by Core Animation: nothing here is updated per frame.
            text.opacity(0).overlay {
                ShimmerWords(text: line.text, font: Typography.monoChip.scaled(by: scale).nsFont,
                             base: Self.ink(.acting, surface: surface, shimmering: true), ink: surface.ink, period: Self.shimmerPeriod)
            }
        } else {
            text.foregroundStyle(Self.ink(line.look, surface: surface, shimmering: false))
        }
    }
}

/// A broadcast's status line as its row and its board's band say it: the `OperatorBadge`, then
/// `· 2 of 8 done` in `Typography.monoChip` and the surface's secondary ink, outside the needs-you box.
/// The progress keeps its width; the badge's words are what is cut.
struct BroadcastStatusLine: View {
    let line: OperatorLine
    let progress: String?
    @Environment(\.surface) private var surface
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack(spacing: 0) {
            OperatorBadge(line: line)
            if let progress {
                Text(verbatim: " · " + progress).font(Typography.monoChip).foregroundStyle(surface.secondaryInk)
                    .lineLimit(1).fixedSize()
            }
        }
        .frame(height: scale(Size.chip))
    }
}

#if DEBUG
extension OperatorBadge {
    /// How many times a shimmering line's words view has been updated, which a test reads to show the
    /// sweep is Core Animation's rather than an update per frame. Debug builds only.
    @MainActor static var shimmerUpdates = 0
}
#endif

/// The shimmering words: drawn by `ShimmerWordsView`, so the sweep runs on Core Animation's clock in the
/// window server, as `StatusMark`'s turn does.
private struct ShimmerWords: NSViewRepresentable {
    let text: String
    let font: NSFont
    let base: Color
    let ink: Color
    let period: Double

    func makeNSView(context: Context) -> ShimmerWordsView { ShimmerWordsView() }

    func updateNSView(_ view: ShimmerWordsView, context: Context) {
        #if DEBUG
        OperatorBadge.shimmerUpdates += 1
        #endif
        view.configure(text: text, font: font, base: NSColor(base), ink: NSColor(ink), period: period)
    }
}

/// The words twice, in the surface's secondary ink and over them in its ink, the ink masked by a band
/// that fades in and out at its edges and is swept across the words and off them every `period`: a
/// `CABasicAnimation` on the band's position, added once and running for as long as the layer lives.
/// Layer-hosting, so AppKit leaves its layers to it; it passes every click through to its row.
final class ShimmerWordsView: NSView {
    static let sweepKey = "sweep"
    /// The band's width, as a share of the words'.
    private static let bandShare: CGFloat = 0.4
    let base = CATextLayer(), lit = CATextLayer(), band = CAGradientLayer()
    private var text = "", font: NSFont?, baseColor = NSColor.clear, inkColor = NSColor.clear
    private var period: CFTimeInterval = OperatorBadge.shimmerPeriod
    /// The width the running sweep was made for: one for another width is made again.
    private var sweptWidth: CGFloat = 0

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        for words in [base, lit] {
            words.isWrapped = false
            words.truncationMode = .end
            words.alignmentMode = .left
            layer?.addSublayer(words)
        }
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        lit.mask = band
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(text: String, font: NSFont, base: NSColor, ink: NSColor, period: Double) {
        guard text != self.text || font != self.font || base != baseColor || ink != inkColor || period != self.period else { return }
        let restart = period != self.period
        self.text = text; self.font = font; baseColor = base; inkColor = ink; self.period = period
        paint()
        if restart { sweptWidth = 0; sweep() }
    }

    override func layout() {
        super.layout()
        unanimated {
            base.frame = bounds
            lit.frame = bounds
            band.frame = CGRect(x: 0, y: 0, width: bounds.width * Self.bandShare, height: bounds.height)
        }
        sweep()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rescale()
        sweep()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rescale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func rescale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        unanimated { for words in [base, lit] { words.contentsScale = scale } }
    }

    private func paint() {
        guard let font else { return }
        unanimated {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                base.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: baseColor])
                lit.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: inkColor])
                // A mask reads only alpha: the ink, faded out at the band's edges.
                let ink = inkColor.cgColor
                band.colors = [ink.copy(alpha: 0) ?? ink, ink, ink.copy(alpha: 0) ?? ink]
            }
        }
    }

    /// Starts the sweep if the band has none for this width: from just before the words to just past them.
    private func sweep() {
        guard bounds.width > 0, window != nil else { return }
        guard band.animation(forKey: Self.sweepKey) == nil || sweptWidth != bounds.width else { return }
        let half = band.bounds.width / 2
        let pass = CABasicAnimation(keyPath: "position.x")
        pass.fromValue = -half
        pass.toValue = bounds.width + half
        pass.duration = period
        pass.repeatCount = .infinity
        pass.isRemovedOnCompletion = false
        band.add(pass, forKey: Self.sweepKey)
        sweptWidth = bounds.width
    }

    private func unanimated(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}
