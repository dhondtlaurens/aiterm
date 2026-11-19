import AppKit
import SwiftUI
import AiTermUI
import AiTermCore

/// The Operator row’s activity caption. Its words morph only when they change, always drawn by one view of
/// their own (`DecodeWords`); a repeated event, a new ink or a new layout moves nothing. Every word is in the
/// surface’s secondary ink; only needs-you stands out, in its box. Reduce Motion and snapshots show the words still.
struct OperatorBadge: View {
    let line: OperatorLine
    @Environment(\.surface) private var surface
    @Environment(\.interfaceScale) private var scale
    @Environment(\.motionStill) private var motionStill

    /// How long new acting words take to decode, in seconds: calm, once per change, never looped.
    static let decodeDuration = 0.5

    /// The box a look draws, when it draws one.
    struct Box: Equatable { var fill: Color; var stroke: Color? }

    /// The words are drawn by the decode's view whatever they say, so the line never passes from one renderer to
    /// another; under Reduce Motion or in a snapshot they are SwiftUI's text, still.
    static func decodes(motionStill: MotionStill?) -> Bool { motionStill == nil }

    /// One ink for every word, the surface's secondary ink, so a change never switches it; needs-you, in its box,
    /// alone stands out.
    static func ink(_ look: OperatorLine.Look, surface: Surface) -> Color {
        look == .needsYou ? (surface.isOnAccent ? surface.ink : Palette.text) : surface.secondaryInk
    }

    /// Only needs-you has a box: the attention chip's fill and edge, or on the accent its wash alone.
    static func box(_ look: OperatorLine.Look, surface: Surface) -> Box? {
        guard look == .needsYou else { return nil }
        return surface.isOnAccent ? Box(fill: surface.badgeWash, stroke: nil)
            : Box(fill: Palette.statusChipAttentionFill, stroke: Palette.statusChipAttentionStroke)
    }

    var body: some View {
        let decoding = Self.decodes(motionStill: motionStill)
        let box = Self.box(line.look, surface: surface)
        let inset = box == nil ? 0 : scale(Space.tight)
        let ink = Self.ink(line.look, surface: surface)
        let text = Text(line.text).font(Typography.chip).lineLimit(1).truncationMode(.tail)
        // The box hugs the words; the line they are drawn in spans the row, so a change never resizes it and the old
        // words are never cut by the new words' slot.
        text.foregroundStyle(ink).opacity(decoding ? 0 : 1)
            .padding(.horizontal, inset)
            .frame(height: scale(Size.chip))
            .background {
                if let box {
                    Color.clear.chipChrome(fill: box.fill, stroke: box.stroke)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if decoding {
                    // Drawn by the decode's own view: a frame is never a SwiftUI update.
                    text.hidden().frame(maxWidth: .infinity, alignment: .leading)
                        .overlay {
                            DecodeWords(text: line.text, font: Typography.chip.scaled(by: scale).nsFont, ink: ink,
                                        duration: Self.decodeDuration)
                        }
                        .padding(.leading, inset)
                }
            }
            .help(line.tooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(line.tooltip)
    }
}

/// Keep a quick action readable for a second even when its start and result land within one display frame; its
/// result, the same words, morphs nothing. Only this caption holds it; status marks and task rows always show the
/// current workload.
/// A caption that has just appeared (its section unfolded) takes its event as read: it shows the
/// current words and never replays an action that ended before it was drawn.
struct OperatorActivityCaption: View {
    let line: OperatorLine
    var completed: OperatorLine?
    var event: UUID?
    @Environment(\.motionStill) private var motionStill
    @State private var settledEvent: UUID?
    /// One morph plus the same time reading its settled words, interrupted by any newer event.
    private static let hold = 2 * OperatorBadge.decodeDuration

    init(line: OperatorLine, completed: OperatorLine? = nil, event: UUID? = nil) {
        self.line = line; self.completed = completed; self.event = event
        _settledEvent = State(initialValue: event)
    }

    var body: some View {
        let recent = motionStill != .snapshot && event != settledEvent ? completed : nil
        OperatorBadge(line: recent ?? line)
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

/// The Operator's words: drawn by `DecodeWordsView`, which runs its frames itself. `kerning` is the words' own
/// tracking, none in the app's faces today.
struct DecodeWords: NSViewRepresentable {
    let text: String
    let font: NSFont
    let ink: Color
    let duration: Double
    var kerning: CGFloat = 0

    func makeNSView(context: Context) -> DecodeWordsView { DecodeWordsView() }

    func updateNSView(_ view: DecodeWordsView, context: Context) {
        #if DEBUG
        OperatorBadge.decodeUpdates += 1
        #endif
        view.configure(text: text, font: font, ink: NSColor(ink), duration: duration, kerning: kerning)
    }
}

/// Words that morph once when they change, from the words standing to the new ones: the new words settle from the
/// left over `duration`, a frame every `1 / frameRate` s, then stand still. Ahead of them runs a band of `band`
/// characters, each letter or digit a glyph of its own case (`glyphs(for:)`), so a capital stays a capital and a
/// number a number; past the band the old words still stand. Spaces and separators are never scrambled. The first
/// words it is given stand as they are, so the line always runs from words to words, never from or into nothing.
///
/// One layer draws the line (`DecodeLine`), layer-hosting, so AppKit leaves its layer to it. It draws with AppKit's
/// own tail truncation in the words' face, so a line a hair wider than its slot ends in an ellipsis rather than
/// vanishing, and it never animates on its own: each frame is drawn as it is, never faded or stretched from the last.
/// It passes every click through to its row. Its clock is `now`, Core Animation's media time unless a test drives it,
/// each frame drawn by `tick`.
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
    /// How many characters scramble at once, between the settled new words and the old ones still standing.
    static let band = 4
    /// The line, as it is drawn.
    let line = DecodeLine()
    /// The decode's clock, in seconds.
    var now: () -> CFTimeInterval = CACurrentMediaTime
    /// What it draws now: a frame of the morph, or the words once settled.
    private(set) var shown = ""
    /// Frames drawn since it was made, which a test reads to show the decode stops.
    private(set) var frames = 0
    private(set) var font: NSFont?
    private var text = "", from = "", inkColor = NSColor.clear, kerning: CGFloat = 0
    private var duration: CFTimeInterval = OperatorBadge.decodeDuration
    /// When the running morph began; nil once it settled.
    private var began: CFTimeInterval?
    private var timer: Timer?

    var isDecoding: Bool { began != nil }

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(line)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// New words morph from the words standing, except the first words, which stand as they are; the same words, in
    /// another ink or face or for another event, are only redrawn.
    func configure(text: String, font: NSFont, ink: NSColor, duration: Double, kerning: CGFloat = 0) {
        let changed = text != self.text, first = self.font == nil
        guard changed || font != self.font || ink != inkColor || duration != self.duration || kerning != self.kerning else { return }
        let standing = shown
        self.text = text; self.font = font; inkColor = ink; self.duration = duration; self.kerning = kerning
        if changed && !first { start(from: standing) } else { if !isDecoding { shown = text }; paint() }
    }

    /// The morph's frame at `now`: the next frame while it runs, the words and the end of it once its time is up.
    func tick() {
        guard let began else { return }
        let progress = duration > 0 ? (now() - began) / duration : 1
        frames += 1
        if progress >= 1 {
            stop()
            shown = text
        } else {
            shown = Self.frame(from: from, to: text, progress: progress, step: frames)
        }
        paint()
    }

    /// The line `progress` of the way from `from` to `to`: the new words settled from the left, then a band of
    /// `band` characters scrambling, each letter or digit a glyph of its case picked by its place and the frame's
    /// `step`, everything else as it is, then the old words still standing. At 0 it is `from`, at 1 `to`.
    static func frame(from: String, to: String, progress: Double, step: Int) -> String {
        let old = Array(from), new = Array(to), count = max(old.count, new.count)
        let settled = Int(Double(count + band) * min(max(progress, 0), 1)) - band
        var frame = ""
        for index in 0..<count {
            if index < settled {
                if index < new.count { frame.append(new[index]) }
            } else if index < settled + band {
                guard let character = index < new.count ? new[index] : index < old.count ? old[index] : nil else { continue }
                guard character.isLetter || character.isNumber else { frame.append(character); continue }
                let pick = (index + 1) &* 7919 &+ (step + 1) &* 104_729 &+ index &* step &* 31
                let glyphs = Self.glyphs(for: character)
                frame.append(glyphs[abs(pick) % glyphs.count])
            } else if index < old.count {
                frame.append(old[index])
            }
        }
        return frame
    }

    private func start(from standing: String) {
        from = standing
        began = now()
        shown = Self.frame(from: from, to: text, progress: 0, step: frames)
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
        // Gone from its row mid-morph: no frame is drawn for no one.
        if isDecoding { stop(); shown = text; paint() }
        super.removeFromSuperview()
    }

    override func layout() {
        super.layout()
        place()
    }

    /// The line fills the view.
    private func place() {
        unanimated { line.frame = bounds }
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
        guard line.contentsScale != scale else { return }
        unanimated { line.contentsScale = scale; line.setNeedsDisplay() }
    }

    /// `words` as the line draws them: in the face, its tracking and `ink`, cut at the tail when they do not fit.
    static func painted(_ words: String, font: NSFont, kerning: CGFloat = 0, ink: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: words, attributes: [.font: font, .kern: kerning, .foregroundColor: ink,
                                                              .paragraphStyle: paragraph])
    }

    private func paint() {
        guard let font else { return }
        // The ink is resolved here, in the view's appearance; the layer draws later, outside it.
        var ink = inkColor
        effectiveAppearance.performAsCurrentDrawingAppearance { ink = NSColor(cgColor: inkColor.cgColor) ?? inkColor }
        let words = Self.painted(shown, font: font, kerning: kerning, ink: ink)
        unanimated { line.words = words }
    }

    private func unanimated(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}

/// The decoding line's own layer: its words drawn by AppKit, top-aligned and cut at the tail in their own face. It has
/// no implicit animations: Core Animation would fade each redraw in over a quarter second from the last, stretched to
/// the new size, so the words would blur, change weight and flash bigger. A bitmap of another size is never scaled.
final class DecodeLine: CALayer {
    var words = NSAttributedString() {
        didSet { if words != oldValue { setNeedsDisplay() } }
    }

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        contentsGravity = .left
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let line = layer as? DecodeLine { words = line.words }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func action(forKey event: String) -> CAAction? { nil }

    override func draw(in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        words.draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }
}
