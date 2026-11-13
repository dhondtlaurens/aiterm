import AppKit
import SwiftUI
import Testing
import AiTermUI
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The operator badge draws an `OperatorLine` (spec §7, §13, §14): its words alone, no mark, one
/// `Size.chip` line whatever it says, quiet with no box, acting with no box in the surface's ink, needs-you in the
/// attention chip's pair — a selected row's too, which is neutral — and on the accent the surface's wash and ink. Acting words decode through glyphs once
/// when they change, then stand still (P3, decision 3): at once under Reduce Motion and in the snapshots.
@MainActor
struct OperatorBadgeTests {
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

    /// Each frame of the decode: the words settled from the left up to the frame's share, the rest a letter or digit
    /// of the character's case each, their spaces and separators kept, so the line keeps its length; painted, the words layer draws the real
    /// characters, so it keeps its width too, in the chip face and the heading's section face alike — both
    /// proportional, so each glyph is kerned to its character's advance — and the glyphs are a layer of their own,
    /// in the words' ink.
    @Test func aDecodeFrameSettlesFromTheLeftAndKeepsTheLinesWidth() {
        let text = "answering Claude · PAY-231"
        func width(_ string: NSAttributedString) -> CGFloat { string.size().width }
        for (font, kerning) in [(Typography.chip.nsFont, CGFloat(0)), (SidebarHeading.style.nsFont, CGFloat(0))] {
            let words = NSAttributedString(string: text, attributes: [.font: font, .kern: kerning])
            for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
                let frame = DecodeWordsView.frame(of: text, progress: progress, step: Int(progress * 10))
                let painted = DecodeWordsView.painted(frame, text: text, font: font, kerning: kerning, ink: .white)
                #expect(painted.words.string == text && abs(width(painted.words) - width(words)) < 0.01, "\(frame)")
                #expect(painted.glyphs.string == frame)
                painted.glyphs.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: painted.glyphs.length)) { ink, _, _ in
                    #expect([NSColor.white, .clear].contains(ink as? NSColor), "a glyph in the words' ink, nothing green")
                }
            }
        }
        let scrambled = DecodeWordsView.frame(of: text, progress: 0, step: 3)
        for (shown, real) in zip(scrambled, text) where real.isLetter || real.isNumber {
            #expect(DecodeWordsView.glyphs(for: real).contains(shown), "\(real) runs through its own case: \(scrambled)")
        }
        for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
            let frame = DecodeWordsView.frame(of: text, progress: progress, step: Int(progress * 10))
            #expect(frame.count == text.count)
            for (shown, real) in zip(frame, text) where !(real.isLetter || real.isNumber) { #expect(shown == real, "\(frame)") }
            let settled = Int(Double(text.count) * progress)
            #expect(frame.hasPrefix(String(text.prefix(settled))), "\(frame)")
        }
        #expect(DecodeWordsView.frame(of: text, progress: 0, step: 0) != text, "it starts scrambled")
        #expect(DecodeWordsView.frame(of: text, progress: 1, step: 9) == text)
        #expect(DecodeWordsView.frame(of: text, progress: 0.2, step: 1) != DecodeWordsView.frame(of: text, progress: 0.2, step: 2),
                "the glyphs change from frame to frame")
    }

    /// On a clock the test drives: new words decode once over `decodeDuration`, then stand still; the same words
    /// again, or another ink (the row selected), start nothing.
    @Test func newWordsDecodeOnceOnTheClockThenStandStill() {
        var now: CFTimeInterval = 100
        let view = DecodeWordsView()
        view.now = { now }
        let font = Typography.chip.nsFont, duration = OperatorBadge.decodeDuration
        #expect((0.4...0.6).contains(duration), "calm: about half a second")
        view.configure(text: "Operator watching", font: font, ink: .white, duration: duration)
        #expect(view.isDecoding && view.shown != "Operator watching" && view.shown.count == "Operator watching".count)
        now += duration / 2
        view.tick()
        #expect(view.isDecoding && view.shown.hasPrefix("Operat") && view.shown != "Operator watching", "\(view.shown)")
        now += duration / 2
        view.tick()
        #expect(!view.isDecoding && view.shown == "Operator watching", "settled at its end")
        let frames = view.frames
        now += 5
        view.tick()
        #expect(view.frames == frames && view.shown == "Operator watching", "it never loops")
        view.configure(text: "Operator watching", font: font, ink: .black, duration: duration)
        #expect(!view.isDecoding, "a new ink is no new words")
        view.configure(text: "ready for the Operator", font: font, ink: .black, duration: duration)
        #expect(view.isDecoding && view.shown != "ready for the Operator", "new words decode again")
    }

    /// The Operator heading's decode: its first words stand as they are, so a heading that appears does not decode
    /// its own name; the next words decode, in their own case — the heading is sentence case, so it reads
    /// "Operator" at rest and the row's line as the line writes it, never in capitals — and nothing glows.
    @Test func firstWordsCanStandAndNothingGlows() {
        var now: CFTimeInterval = 100
        let view = DecodeWordsView()
        view.now = { now }
        let font = SidebarHeading.style.nsFont
        #expect(OperatorTitle.home == "Operator")
        view.configure(text: OperatorTitle.home, font: font, ink: .white, duration: OperatorTitle.decodeDuration, decodesFirst: false)
        #expect(!view.isDecoding && view.shown == "Operator")
        let line = OperatorLine("answering Claude · PAY-231", look: .acting)
        view.configure(text: line.text, font: font, ink: .white, duration: OperatorTitle.decodeDuration, decodesFirst: false)
        #expect(view.isDecoding && view.shown != line.text)
        #expect(view.glyphs.shadowOpacity == 0 && view.words.shadowOpacity == 0, "no glow")
        now += OperatorTitle.decodeDuration
        view.tick()
        #expect(!view.isDecoding && view.shown == "answering Claude · PAY-231", "settled in the line's own case")
    }

    /// The decode keeps its timing and rules (sentence-case headings, 13 Nov 2026, changed only the case): 0.9 s
    /// each way, 0.35 s back under the pointer, a 3 s hold and a 20–60 s rest.
    @Test func theHeadingsDecodeKeepsItsTiming() {
        #expect(OperatorTitle.decodeDuration == 0.9)
        #expect(OperatorTitle.hoverDuration == 0.35)
        #expect(OperatorTitle.hold == 3.0)
        #expect(OperatorTitle.rest == 20...60)
    }

    /// Hosted on the wall clock: the decode runs once in its own view, a frame at a time, settles within its
    /// duration and stops; the badge's SwiftUI view is not updated per frame, and nothing decodes when it stands still.
    @Test func theDecodeSettlesAndStopsWithoutAnUpdatePerFrame() throws {
        func hosted(_ view: some View) -> (NSWindow, NSView) {
            let host = NSHostingView(rootView: view.padding(Space.base).background(Palette.sidebar).surface(.sidebar))
            host.appearance = NSAppearance(named: .darkAqua)
            let window = testWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40), styleMask: [.borderless])
            window.contentView = host
            window.orderFrontRegardless()
            return (window, host)
        }
        let before = OperatorBadge.decodeUpdates
        let (window, host) = hosted(OperatorBadge(line: OperatorLine("consulting the Oracle", look: .acting)))
        defer { window.close() }
        settle(host) { host.firstDescendant(DecodeWordsView.self) != nil }
        let words = try #require(host.firstDescendant(DecodeWordsView.self))
        #expect(words.bounds.width > 0 && words.bounds.height > 0, "the acting status has a visible text slot")
        #expect(words.words.frame.size == words.bounds.size, "its text layer fills that slot")
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
                #expect(!words.shown.isEmpty && !words.words.frame.isEmpty)
                settle(host) { !words.isDecoding }
                #expect(words.shown == line.text)
            } else {
                #expect(host.firstDescendant(DecodeWordsView.self) == nil)
                #expect(host.fittingSize.height >= Size.chip)
            }
        }
    }
}
