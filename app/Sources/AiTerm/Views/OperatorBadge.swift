import AppKit
import SwiftUI
import AiTermUI
import AiTermCore

/// The Operator row’s activity caption. New event identities decode even when their words repeat;
/// ordinary view updates (selection, ink, layout) do not. Quiet/result/attention events keep their
/// own ink and needs-you chrome. Reduce Motion and snapshots show the real words immediately.
struct OperatorBadge: View {
    let line: OperatorLine
    var event: UUID? = nil
    @Environment(\.surface) private var surface
    @Environment(\.interfaceScale) private var scale
    @Environment(\.motionStill) private var motionStill

    /// How long new acting words take to decode, in seconds: calm, once per change, never looped.
    static let decodeDuration = 0.5

    /// The box a look draws, when it draws one.
    struct Box: Equatable { var fill: Color; var stroke: Color? }

    /// Acting words and explicit events decode, except under Reduce Motion or in a snapshot.
    static func decodes(_ look: OperatorLine.Look, motionStill: MotionStill?, event: UUID? = nil) -> Bool {
        (look == .acting || event != nil) && motionStill == nil
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
        let decoding = Self.decodes(line.look, motionStill: motionStill, event: event)
        let box = Self.box(line.look, surface: surface)
        words(decoding: decoding)
            .padding(.horizontal, box == nil ? 0 : scale(Space.tight))
            .frame(height: scale(Size.chip))
            .background {
                if let box {
                    Color.clear.chipChrome(fill: box.fill, stroke: box.stroke)
                }
            }
            .help(line.tooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.tooltip)
    }

    @ViewBuilder
    private func words(decoding: Bool) -> some View {
        let text = Text(line.text).font(Typography.chip).lineLimit(1).truncationMode(.tail)
        if decoding {
            // Laid out by the final words, drawn by the decode's own view: a frame is never a SwiftUI update.
            text.opacity(0).overlay {
                DecodeWords(text: line.text, font: Typography.chip.scaled(by: scale).nsFont,
                            ink: Self.ink(line.look, surface: surface), duration: Self.decodeDuration, event: event)
            }
        } else {
            text.foregroundStyle(Self.ink(line.look, surface: surface))
        }
    }
}

/// Keep a quick action readable even when its start and result land within one display frame.
/// Only this caption holds it; status marks and task rows always show the current workload.
struct OperatorActivityCaption: View {
    let line: OperatorLine
    var completed: OperatorLine?
    var event: UUID?
    @Environment(\.motionStill) private var motionStill
    @State private var settledEvent: UUID?
    /// One decode plus the same time reading its settled words, interrupted by any newer event.
    private static let hold = 2 * OperatorBadge.decodeDuration

    var body: some View {
        let recent = motionStill != .snapshot && event != settledEvent ? completed : nil
        OperatorBadge(line: recent ?? line, event: event)
            .task(id: event) {
                guard completed != nil, motionStill != .snapshot else { return }
                try? await Task.sleep(for: .seconds(Self.hold))
                guard !Task.isCancelled else { return }
                settledEvent = event
            }
    }
}

#if DEBUG
extension OperatorBadge {
    /// How many times a decoding line's words view has been updated, which a test reads to show the
    /// decode's frames are its own view's rather than SwiftUI updates. Debug builds only.
    @MainActor static var decodeUpdates = 0
}
#endif

/// The decoding words: drawn by `DecodeWordsView`, which runs its frames itself. `kerning` is the words' own
/// tracking, none in the app's faces today; `decodesFirst` false shows the first words as they are, so a heading
/// that appears does not decode its own name.
struct DecodeWords: NSViewRepresentable {
    let text: String
    let font: NSFont
    let ink: Color
    let duration: Double
    var kerning: CGFloat = 0
    var decodesFirst = true
    var event: UUID? = nil

    func makeNSView(context: Context) -> DecodeWordsView { DecodeWordsView() }

    func updateNSView(_ view: DecodeWordsView, context: Context) {
        #if DEBUG
        OperatorBadge.decodeUpdates += 1
        #endif
        view.configure(text: text, font: font, ink: NSColor(ink), duration: duration, kerning: kerning, decodesFirst: decodesFirst, event: event)
    }
}

/// Words that decode once when they change: each letter and digit runs through `glyphs(for:)`, letters and digits
/// in its own case, so a capital stays a capital and a number a number, in the words' own ink, and the words settle
/// from the left over `duration`, a frame every `1 / frameRate` s, then stand still; spaces and separators stay put.
/// The words layer always draws the real characters, clear where a glyph stands, so the words never change their
/// width, in the chip face or the heading's; each glyph is kerned to stand where its character does (`painted`).
/// Two `CATextLayer`s, layer-hosting, so AppKit leaves its layer to it: the words, and over them the unsettled
/// glyphs alone, so no pair of glyphs ever kerns the words' line wider or narrower than its own letters. It passes
/// every click through to its row. Its clock is `now`, Core Animation's media time unless a test drives it, each
/// frame drawn by `tick`.
final class DecodeWordsView: NSView {
    /// What a character runs through while it decodes: a digit, digits; a capital, capitals and digits; any
    /// other letter, lowercase letters and digits.
    static func glyphs(for character: Character) -> [Character] {
        character.isNumber ? digits : character.isUppercase ? capitals : lowercase
    }
    private static let digits = Array("0123456789")
    private static let capitals = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let lowercase = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    static let frameRate = 30.0
    let words = CATextLayer()
    /// The unsettled glyphs, in the words' ink.
    let glyphs = CATextLayer()
    /// The decode's clock, in seconds.
    var now: () -> CFTimeInterval = CACurrentMediaTime
    /// What it draws now: a frame of the decode, or the words once settled.
    private(set) var shown = ""
    /// Frames drawn since it was made, which a test reads to show the decode stops.
    private(set) var frames = 0
    private var text = "", font: NSFont?, inkColor = NSColor.clear, kerning: CGFloat = 0
    private var duration: CFTimeInterval = OperatorBadge.decodeDuration
    /// When the running decode began; nil once it settled.
    private var began: CFTimeInterval?
    private var event: UUID?
    private var timer: Timer?

    var isDecoding: Bool { began != nil }

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        for text in [words, glyphs] {
            text.isWrapped = false
            text.truncationMode = .end
            text.alignmentMode = .left
            layer?.addSublayer(text)
        }
        // A glyph a hair past the edge is clipped, never cut with an ellipsis of its own.
        glyphs.truncationMode = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A new event or new words start a decode — the first ones too, unless `decodesFirst` is false; the same words in another ink
    /// or face are only redrawn.
    func configure(text: String, font: NSFont, ink: NSColor, duration: Double, kerning: CGFloat = 0, decodesFirst: Bool = true, event: UUID? = nil) {
        let changed = text != self.text || event != self.event, first = self.font == nil
        guard changed || font != self.font || ink != inkColor || duration != self.duration || kerning != self.kerning else { return }
        self.text = text; self.font = font; inkColor = ink; self.duration = duration; self.kerning = kerning; self.event = event
        if changed && (decodesFirst || !first) { start() } else { if !isDecoding { shown = text }; paint() }
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
    /// letter or digit after it a glyph of its case picked by its place and the frame's `step`, everything else as
    /// it is.
    static func frame(of text: String, progress: Double, step: Int) -> String {
        let settled = Int(Double(text.count) * min(max(progress, 0), 1))
        return String(text.enumerated().map { index, character in
            guard index >= settled, character.isLetter || character.isNumber else { return character }
            let pick = (index + 1) &* 7919 &+ (step + 1) &* 104_729 &+ index &* step &* 31
            let glyphs = Self.glyphs(for: character)
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
        unanimated { words.frame = bounds; glyphs.frame = bounds }
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
        unanimated { words.contentsScale = scale; glyphs.contentsScale = scale }
    }

    /// `shown` against its `text`, as the two layers draw it: the words, always the real characters, in `ink` where
    /// settled and clear where a glyph stands, so the line is exactly as wide as its words in every frame; and over
    /// them the glyphs alone, in `ink` too, each kerned by the difference between its advance and its character's so
    /// it stands where that character does, the settled characters clear.
    static func painted(_ shown: String, text: String, font: NSFont, kerning: CGFloat = 0,
                        ink: NSColor) -> (words: NSAttributedString, glyphs: NSAttributedString) {
        func advance(_ character: Character) -> CGFloat {
            NSAttributedString(string: String(character), attributes: [.font: font]).size().width
        }
        let words = NSMutableAttributedString(), glyphs = NSMutableAttributedString()
        for (glyph, real) in zip(shown, text) {
            let unsettled = glyph != real
            words.append(NSAttributedString(string: String(real), attributes: [.font: font, .kern: kerning,
                                                                               .foregroundColor: unsettled ? NSColor.clear : ink]))
            glyphs.append(NSAttributedString(string: String(glyph), attributes: [
                .font: font, .kern: kerning + (unsettled ? advance(real) - advance(glyph) : 0),
                .foregroundColor: unsettled ? ink : NSColor.clear]))
        }
        return (words, glyphs)
    }

    private func paint() {
        guard let font else { return }
        unanimated {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let painted = Self.painted(shown, text: text, font: font, kerning: kerning, ink: inkColor)
                words.string = painted.words
                glyphs.string = painted.glyphs
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
