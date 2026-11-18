import AppKit
import SwiftUI
import Testing
import AiTermUI
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The operator badge draws an `OperatorLine`: its words alone, no mark, one
/// `Size.chip` line whatever it says, quiet with no box, acting with no box in the surface's ink, needs-you in the
/// attention chip's pair — a selected row's too, which is neutral — and on the accent the surface's wash and ink. Acting words decode through glyphs once
/// when they change, then stand still (P3, decision 3): at once under Reduce Motion and in the snapshots.
@MainActor
struct OperatorBadgeTests {
    private func caption(_ line: OperatorLine, completed: OperatorLine? = nil, event: UUID) -> some View {
        OperatorActivityCaption(line: line, completed: completed, event: event).frame(width: 280, height: Size.chip).surface(.sidebar)
    }

    @Test func aQuickCompletedActionIsReadableBeforeTheCaptionReturnsToWatching() async throws {
        let watching = OperatorLine("watching 1 task in 1 signal")
        let completed = OperatorLine("reading status", look: .acting)
        let host = testHost(caption(watching, event: UUID()), size: CGSize(width: 280, height: Size.chip))
        let window = testWindow(hosting: host, styleMask: [.borderless])
        defer { window.close() }
        settle(host) { host.firstDescendant(DecodeWordsView.self) != nil }
        // The action started and ended within one frame: only its completed event reaches the row.
        host.rootView = caption(watching, completed: completed, event: UUID())
        await eventually(describing: "the completed action to be read") {
            host.layoutSubtreeIfNeeded()
            return host.firstDescendant(DecodeWordsView.self)?.shown == completed.text
        }
        await eventually(describing: "the completed activity to return to watching") {
            host.layoutSubtreeIfNeeded()
            let current = host.firstDescendant(DecodeWordsView.self)
            return current?.shown == watching.text && current?.isDecoding == false
        }
        #expect(host.firstDescendant(DecodeWordsView.self)?.shown == watching.text)
    }

    /// Unfolding the Operator section draws a new caption: it shows the current words at once, neither decoding them
    /// nor replaying an action that ended while it was folded.
    @Test func aCaptionThatAppearsShowsItsWordsWithoutReplayingAnEndedAction() {
        let watching = OperatorLine("watching 3 tasks in 2 signals")
        let host = testHost(caption(watching, completed: OperatorLine("reading status", look: .acting), event: UUID()),
                            size: CGSize(width: 280, height: Size.chip), appearance: NSAppearance(named: .darkAqua))
        let window = testWindow(hosting: host, styleMask: [.borderless])
        defer { window.close() }
        settle(host) { host.firstDescendant(DecodeWordsView.self) != nil }
        let words = host.firstDescendant(DecodeWordsView.self)
        #expect(words?.shown == watching.text && words?.isDecoding == false)
        settle(host, for: 0.2)
        #expect(words?.frames == 0, "nothing decoded")
    }

    @Test func aNewEventRetriggersIdenticalWordsButSelectionDoesNot() {
        var now: CFTimeInterval = 100
        let view = DecodeWordsView(), first = UUID(), second = UUID()
        view.now = { now }
        let font = Typography.chip.nsFont, duration = OperatorBadge.decodeDuration
        view.configure(text: "reading status", font: font, ink: .white, duration: duration, event: first)
        #expect(!view.isDecoding && view.shown == "reading status", "the first words stand")
        view.configure(text: "reading status", font: font, ink: .gray, duration: duration, event: first)
        #expect(!view.isDecoding)
        view.configure(text: "reading status", font: font, ink: .gray, duration: duration, event: second)
        #expect(view.isDecoding && view.shown == "reading status", "it starts from the words standing")
        now += duration / 2; view.tick()
        #expect(view.shown != "reading status" && view.shown.count == "reading status".count, "a band scrambles: \(view.shown)")
        #expect(OperatorBadge.decodes(.quiet, motionStill: nil, event: second))
        #expect(OperatorBadge.decodes(.needsYou, motionStill: nil, event: second))
        #expect(!OperatorBadge.decodes(.quiet, motionStill: .reduceMotion, event: second))
        #expect(!OperatorBadge.decodes(.acting, motionStill: .snapshot, event: second))
        now += duration; view.tick()
        #expect(!view.isDecoding && view.shown == "reading status")
    }

    private func fitting(_ line: OperatorLine, width: CGFloat? = nil) -> CGSize {
        let host = NSHostingView(rootView: OperatorBadge(line: line).frame(width: width, alignment: .leading)
            .surface(.sidebar).environment(\.motionStill, .snapshot))
        return host.fittingSize
    }

    @Test func oneLineAlways() {
        let long = OperatorLine(String(repeating: "blocked · a very long reason ", count: 4), look: .needsYou)
        for line in [long, OperatorLine("queued"), OperatorLine("consulting the Oracle", look: .acting)] {
            #expect(fitting(line).height == Size.chip, "\(line.text)")
        }
        // Squeezed into a narrow column it cuts its words rather than wrap.
        #expect(fitting(long, width: 120).height == Size.chip)
    }

    @Test func stillUnderReduceMotion() {
        #expect(OperatorBadge.decodes(.acting, motionStill: nil))
        #expect(!OperatorBadge.decodes(.acting, motionStill: .reduceMotion))
        #expect(!OperatorBadge.decodes(.acting, motionStill: .snapshot))
        #expect(!OperatorBadge.decodes(.quiet, motionStill: nil))
        #expect(!OperatorBadge.decodes(.needsYou, motionStill: nil))
        // Acting stands in the surface's ink, decoding or not; quiet sits back in its secondary ink.
        for surface in [Surface.sidebar, .selected, .accent] {
            #expect(OperatorBadge.ink(.acting, surface: surface) == surface.ink)
            #expect(OperatorBadge.ink(.quiet, surface: surface) == surface.secondaryInk)
        }
        // A still acting badge draws the same twice: nothing moves in a snapshot.
        let line = OperatorLine("answering Claude", look: .acting)
        let view = OperatorBadge(line: line).padding(Space.base).background(Palette.sidebar).surface(.sidebar)
        let first = Snapshots.png(of: Snapshot("badge.png") { view }), second = Snapshots.png(of: Snapshot("badge.png") { view })
        #expect(first != nil && first == second)
    }

    @Test func needsYouIsTheAttentionChipOffTheAccentAndTheWashOnIt() {
        #expect(OperatorBadge.box(.needsYou, surface: .sidebar) == .init(fill: Palette.statusChipAttentionFill, stroke: Palette.statusChipAttentionStroke))
        // A selected row is neutral: the attention pair holds there, and so does the plain ink.
        #expect(OperatorBadge.box(.needsYou, surface: .selected) == .init(fill: Palette.statusChipAttentionFill, stroke: Palette.statusChipAttentionStroke))
        #expect(OperatorBadge.ink(.needsYou, surface: .selected) == Palette.text)
        #expect(OperatorBadge.box(.needsYou, surface: .accent) == .init(fill: Surface.accent.badgeWash, stroke: nil))
        #expect(OperatorBadge.ink(.needsYou, surface: .sidebar) == Palette.text)
        #expect(OperatorBadge.ink(.needsYou, surface: .accent) == Surface.accent.ink)
        for surface in [Surface.sidebar, .selected, .accent] {
            #expect(OperatorBadge.box(.quiet, surface: surface) == nil)
            #expect(OperatorBadge.box(.acting, surface: surface) == nil, "acting has no box")
        }
    }

    @Test func theWordsStandAloneWithNoMark() {
        // Quiet and acting draw no box, so the badge is as wide as its words: no mark leads them.
        // Words, in the system face (`Typography.chip`): the monospaced face is for code alone.
        let words = NSHostingView(rootView: Text("merging").font(Typography.chip).fixedSize()).fittingSize.width
        #expect(fitting(OperatorLine("merging")).width == words)
        #expect(fitting(OperatorLine("merging", look: .acting)).width == words)
        // Needs you adds only its box's inset either side.
        #expect(fitting(OperatorLine("merging", look: .needsYou)).width == words + 2 * Space.tight)
    }

    /// Each frame of the morph runs from the old words to the new: the new words settled from the left, a band of
    /// glyphs of each character's case, then the old words still standing; spaces and separators kept. It starts
    /// as the old words, ends as the new, and is never empty, growing or shrinking to the new words' length.
    @Test func aMorphFrameRunsFromTheOldWordsToTheNew() {
        let pairs = [("watching 3 tasks in 2 signals", "working"), ("working", "answering Claude · PAY-231"),
                     ("reading status", "reading status")]
        for (from, to) in pairs {
            #expect(DecodeWordsView.frame(from: from, to: to, progress: 0, step: 0) == from, "it starts as the old words")
            #expect(DecodeWordsView.frame(from: from, to: to, progress: 1, step: 9) == to, "it ends as the new words")
            let count = max(from.count, to.count), band = DecodeWordsView.band
            for step in 0...20 {
                let progress = Double(step) / 20
                let frame = DecodeWordsView.frame(from: from, to: to, progress: progress, step: step)
                #expect(!frame.isEmpty, "never nothing: \(from) → \(to) at \(progress)")
                let settled = Int(Double(count + band) * progress) - band
                #expect(frame.hasPrefix(String(to.prefix(max(settled, 0)))), "\(frame)")
                if settled + band < from.count {
                    #expect(frame.hasSuffix(String(from.dropFirst(max(settled + band, 0)))), "the old words stand past the band: \(frame)")
                }
            }
        }
        let text = "answering Claude · PAY-231"
        let scrambled = DecodeWordsView.frame(from: text, to: text, progress: 0.5, step: 3)
        #expect(scrambled.count == text.count && scrambled != text)
        for (shown, real) in zip(scrambled, text) {
            if real.isLetter || real.isNumber {
                #expect(DecodeWordsView.glyphs(for: real).contains(shown), "\(real) runs through its own case: \(scrambled)")
            } else {
                #expect(shown == real, "separators stay put: \(scrambled)")
            }
        }
        #expect(DecodeWordsView.frame(from: "watching", to: text, progress: 0.4, step: 1)
                != DecodeWordsView.frame(from: "watching", to: text, progress: 0.4, step: 2), "the glyphs change from frame to frame")
    }

    /// On a clock the test drives: the first words stand; new words morph once over `decodeDuration`, then stand
    /// still; the same words again, or another ink (the row selected), start nothing.
    @Test func newWordsDecodeOnceOnTheClockThenStandStill() {
        var now: CFTimeInterval = 100
        let view = DecodeWordsView()
        view.now = { now }
        let font = Typography.chip.nsFont, duration = OperatorBadge.decodeDuration
        #expect((0.4...0.6).contains(duration), "calm: about half a second")
        view.configure(text: "Operator watching", font: font, ink: .white, duration: duration)
        #expect(!view.isDecoding && view.shown == "Operator watching", "the first words stand as they are")
        view.configure(text: "ready for the Operator", font: font, ink: .white, duration: duration)
        #expect(view.isDecoding && view.shown == "Operator watching", "it starts from the words standing")
        now += duration / 2
        view.tick()
        #expect(view.isDecoding && view.shown.hasPrefix("ready ") && view.shown != "ready for the Operator", "\(view.shown)")
        now += duration / 2
        view.tick()
        #expect(!view.isDecoding && view.shown == "ready for the Operator", "settled at its end")
        let frames = view.frames
        now += 5
        view.tick()
        #expect(view.frames == frames && view.shown == "ready for the Operator", "it never loops")
        view.configure(text: "ready for the Operator", font: font, ink: .black, duration: duration)
        #expect(!view.isDecoding, "a new ink is no new words")
    }

    /// Ink a layer draws, in pixels at 2x: what a person sees of it.
    private func inked(_ layer: CALayer) -> Int {
        let width = Int(layer.bounds.width * 2), height = Int(layer.bounds.height * 2)
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                                             bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        context.scaleBy(x: 2, y: 2)
        layer.render(in: context)
        return (0..<(width * height)).reduce(0) { $0 + (data[$1 * 4 + 3] > 40 ? 1 : 0) }
    }

    /// The caption once was empty: its settled words sat in a text layer that cut a line a hair wider than its slot
    /// with an ellipsis in a 36 pt face of its own, which drew nothing. At every interface scale the words are drawn,
    /// in every frame of a morph and once settled, and a morph to shorter words keeps the old words' width until it ends.
    @Test(arguments: InterfaceScale.all)
    func theWordsAreDrawnInEveryFrameAndOnceSettled(scale: InterfaceScale) throws {
        func badge(_ text: String, event: UUID) -> some View {
            OperatorBadge(line: OperatorLine(text), event: event).interfaceScale(scale).surface(.washed)
        }
        let long = "watching 3 tasks in 2 signals", short = "working"
        let host = testHost(badge(long, event: UUID()), size: CGSize(width: 280, height: 30), appearance: NSAppearance(named: .darkAqua))
        let window = testWindow(hosting: host, styleMask: [.borderless])
        defer { window.close() }
        settle(host) { host.firstDescendant(DecodeWordsView.self) != nil }
        let words = try #require(host.firstDescendant(DecodeWordsView.self))
        let wide = words.bounds.width
        #expect(words.shown == long && inked(words.line) > 0, "the first words are drawn")
        host.rootView = badge(short, event: UUID())
        settle(host, for: 0.01)
        #expect(words.isDecoding && words.line.frame.width >= wide, "the old words keep their width while they morph")
        var drawn = 0, empty = 0
        settle(host, describing: "the morph to settle") {
            if words.isDecoding { drawn += 1; if inked(words.line) == 0 { empty += 1 } }
            return !words.isDecoding
        }
        #expect(drawn > 0 && empty == 0, "\(empty) of \(drawn) frames drew nothing")
        #expect(words.shown == short && inked(words.line) > 0, "the settled words are drawn")
        #expect(words.line.frame.size == words.bounds.size, "settled, the line fills the new words' slot")
    }

    /// The decode keeps its timing and rules (sentence-case headings, 13 Nov 2026, changed only the case): 0.9 s
    /// each way, 0.35 s back under the pointer, a 3 s hold and a 20–60 s rest.


    /// Hosted on the wall clock: new words decode once in their own view, a frame at a time, settles within its
    /// duration and stops; the badge's SwiftUI view is not updated per frame, and nothing decodes when it stands still.
    @Test func theDecodeSettlesAndStopsWithoutAnUpdatePerFrame() throws {
        func hosted(_ view: some View) -> (NSWindow, NSView) {
            let host = NSHostingView(rootView: AnyView(view.padding(Space.base).background(Palette.sidebar).surface(.sidebar)))
            host.appearance = NSAppearance(named: .darkAqua)
            let window = testWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40), styleMask: [.borderless])
            window.contentView = host
            window.orderFrontRegardless()
            return (window, host)
        }
        let (window, host) = hosted(OperatorBadge(line: OperatorLine("merging", look: .acting)))
        defer { window.close() }
        settle(host) { host.firstDescendant(DecodeWordsView.self) != nil }
        let words = try #require(host.firstDescendant(DecodeWordsView.self))
        let before = OperatorBadge.decodeUpdates
        (host as? NSHostingView<AnyView>)?.rootView = AnyView(OperatorBadge(line: OperatorLine("consulting the Oracle", look: .acting))
            .padding(Space.base).background(Palette.sidebar).surface(.sidebar))
        settle(host, for: 0.01)
        #expect(words.isDecoding, "new words decode")
        #expect(words.bounds.width > 0 && words.bounds.height > 0, "the acting status has a visible text slot")
        settle(host, describing: "the words to settle") { !words.isDecoding && words.shown == "consulting the Oracle" }
        #expect(!words.isDecoding && words.shown == "consulting the Oracle", "settled: \(words.shown)")
        #expect(words.frames > 1, "it decoded a frame at a time")
        let frames = words.frames, updates = OperatorBadge.decodeUpdates
        #expect(updates - before < frames / 2, "the words were updated \(updates - before) times in \(frames) frames")
        settle(host, for: 0.5)
        #expect(words.frames == frames, "it stopped: \(words.frames - frames) more frames")
        #expect(OperatorBadge.decodeUpdates == updates)

        // Standing still (a snapshot here; Reduce Motion takes the same path, `decodes` above) there is no view of its own.
        let (still, stillHost) = hosted(OperatorBadge(line: OperatorLine("merging", look: .acting)).environment(\.motionStill, .snapshot))
        defer { still.close() }
        settle(stillHost, for: 0.1)
        #expect(stillHost.firstDescendant(DecodeWordsView.self) == nil, "standing still, the words are SwiftUI's text")
    }

    /// A row moves repeatedly between the native decoding view and plain SwiftUI text. Returning to
    /// acting after watching or waiting must give the new layer both its words and its layout.
    @Test func secondaryWordsSurviveWorkingWatchingAndWaitingTransitions() throws {
        let host = testHost(OperatorBadge(line: OperatorLine("working", look: .acting)).surface(.washed),
                            size: CGSize(width: 240, height: Size.chip), appearance: NSAppearance(named: .darkAqua))
        let window = testWindow(hosting: host)
        defer { window.orderOut(nil) }
        for line in [OperatorLine("working", look: .acting), OperatorLine("watching 3 tasks"),
                     OperatorLine("in background"), OperatorLine("waiting on you", look: .needsYou),
                     OperatorLine("consulting the Oracle", look: .acting)] {
            host.rootView = OperatorBadge(line: line).surface(.washed)
            settle(host, for: 0.1)
            if line.look == .acting {
                let words = try #require(host.firstDescendant(DecodeWordsView.self))
                #expect(!words.shown.isEmpty && !words.line.frame.isEmpty && inked(words.line) > 0)
                settle(host) { !words.isDecoding }
                #expect(words.shown == line.text)
            } else {
                #expect(host.firstDescendant(DecodeWordsView.self) == nil)
                #expect(host.fittingSize.height >= Size.chip)
            }
        }
    }
}
