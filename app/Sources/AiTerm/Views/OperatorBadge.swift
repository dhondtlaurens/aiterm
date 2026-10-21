import AppKit
import SwiftUI
import AiTermUI
import AiTermCore

/// Everything the Operator says on a status line (spec §7, §13, §14): the words of an `OperatorLine` in
/// `Typography.monoChip`, no mark: where the line sits says whose it is. Always one `Size.chip` line: the
/// words cut with an ellipsis rather than wrap, the whole of them in the tooltip and VoiceOver's label. The
/// last line of a driven task's row and of the Operator's row, a card's last line on the board, the band
/// under the board's title.
///
/// It reads its ground (`Surface`), as `RowCaption(warns:)` does:
/// - quiet, and ended: no box, the words in the surface's secondary ink (an ended row's check is its
///   trailing mark's, `TaskRowMark`, never the line's);
/// - acting: no box, the words in the surface's ink. New words decode once (P3, decision 3, 21 Oct 2026):
///   each character runs through glyphs and they settle from the left over `decodeDuration`, then stand
///   still; the row's spinner carries the ongoing motion (`DecodeWordsView`, its own view, so the row is not
///   redrawn per frame). At once under Reduce Motion and in the snapshots;
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

    /// How long new acting words take to decode, in seconds: calm, once per change, never looped.
    static let decodeDuration = 0.5

    /// The box a look draws, when it draws one.
    struct Box: Equatable { var fill: Color; var stroke: Color? }

    /// Whether new words decode: only while acting, never under Reduce Motion, never in a snapshot.
    static func decodes(_ look: OperatorLine.Look, reduceMotion: Bool, still: Bool) -> Bool {
        look == .acting && !reduceMotion && !still
    }

    /// The words' ink, decoding or standing still.
    static func ink(_ look: OperatorLine.Look, surface: Surface) -> Color {
        switch look {
        case .quiet, .ended: surface.secondaryInk
        case .acting: surface.ink
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
        let decoding = Self.decodes(line.look, reduceMotion: reduceMotion, still: still)
        let box = Self.box(line.look, surface: surface)
        words(decoding: decoding)
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
    private func words(decoding: Bool) -> some View {
        let text = Text(line.text).font(Typography.monoChip).lineLimit(1).truncationMode(.tail)
        if decoding {
            // Laid out by the final words, drawn by the decode's own view: a frame is never a SwiftUI update.
            text.opacity(0).overlay {
                DecodeWords(text: line.text, font: Typography.monoChip.scaled(by: scale).nsFont,
                            ink: Self.ink(.acting, surface: surface), duration: Self.decodeDuration)
            }
        } else {
            text.foregroundStyle(Self.ink(line.look, surface: surface))
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
    /// How many times a decoding line's words view has been updated, which a test reads to show the
    /// decode's frames are its own view's rather than SwiftUI updates. Debug builds only.
    @MainActor static var decodeUpdates = 0
}
#endif

/// The decoding words: drawn by `DecodeWordsView`, which runs its frames itself.
private struct DecodeWords: NSViewRepresentable {
    let text: String
    let font: NSFont
    let ink: Color
    let duration: Double

    func makeNSView(context: Context) -> DecodeWordsView { DecodeWordsView() }

    func updateNSView(_ view: DecodeWordsView, context: Context) {
        #if DEBUG
        OperatorBadge.decodeUpdates += 1
        #endif
        view.configure(text: text, font: font, ink: NSColor(ink), duration: duration)
    }
}

/// Acting words that decode once when they change: each letter and digit runs through `glyphs` and the words
/// settle from the left over `duration`, a frame every `1 / frameRate` s, then stand still; spaces and
/// separators stay put. In the monospaced face every glyph is one advance wide, so the line never changes its
/// width. A `CATextLayer`, layer-hosting, so AppKit leaves its layer to it; it passes every click through to
/// its row. Its clock is `now`, Core Animation's media time unless a test drives it, each frame drawn by `tick`.
final class DecodeWordsView: NSView {
    /// What a character runs through while it decodes.
    static let glyphs = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    static let frameRate = 30.0
    let words = CATextLayer()
    /// The decode's clock, in seconds.
    var now: () -> CFTimeInterval = CACurrentMediaTime
    /// What it draws now: a frame of the decode, or the words once settled.
    private(set) var shown = ""
    /// Frames drawn since it was made, which a test reads to show the decode stops.
    private(set) var frames = 0
    private var text = "", font: NSFont?, inkColor = NSColor.clear
    private var duration: CFTimeInterval = OperatorBadge.decodeDuration
    /// When the running decode began; nil once it settled.
    private var began: CFTimeInterval?
    private var timer: Timer?

    var isDecoding: Bool { began != nil }

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        words.isWrapped = false
        words.truncationMode = .end
        words.alignmentMode = .left
        layer?.addSublayer(words)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// New words start a decode; the same words in another ink or face are only redrawn.
    func configure(text: String, font: NSFont, ink: NSColor, duration: Double) {
        let changed = text != self.text
        guard changed || font != self.font || ink != inkColor || duration != self.duration else { return }
        self.text = text; self.font = font; inkColor = ink; self.duration = duration
        if changed { start() } else { paint() }
    }

    /// The decode's frame at `now`: the next frame while it runs, the words and the end of it once its time is up.
    func tick() {
        guard let began else { return }
        let progress = duration > 0 ? (now() - began) / duration : 1
        frames += 1
        if progress >= 1 {
            stop()
            shown = text
        } else {
            shown = Self.frame(of: text, progress: progress, step: frames)
        }
        paint()
    }

    /// The words `progress` of the way through their decode: settled from the left up to that share, each
    /// letter or digit after it a glyph picked by its place and the frame's `step`, everything else as it is.
    static func frame(of text: String, progress: Double, step: Int) -> String {
        let settled = Int(Double(text.count) * min(max(progress, 0), 1))
        return String(text.enumerated().map { index, character in
            guard index >= settled, character.isLetter || character.isNumber else { return character }
            let pick = (index + 1) &* 7919 &+ (step + 1) &* 104_729 &+ index &* step &* 31
            return glyphs[abs(pick) % glyphs.count]
        })
    }

    private func start() {
        began = now()
        shown = Self.frame(of: text, progress: 0, step: frames)
        paint()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / Self.frameRate, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        began = nil
        timer?.invalidate()
        timer = nil
    }

    override func removeFromSuperview() {
        // Gone from its row mid-decode: no frame is drawn for no one.
        if isDecoding { stop(); shown = text; paint() }
        super.removeFromSuperview()
    }

    override func layout() {
        super.layout()
        unanimated { words.frame = bounds }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rescale()
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
        unanimated { words.contentsScale = scale }
    }

    private func paint() {
        guard let font else { return }
        unanimated {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                words.string = NSAttributedString(string: shown, attributes: [.font: font, .foregroundColor: inkColor])
            }
        }
    }

    private func unanimated(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}
