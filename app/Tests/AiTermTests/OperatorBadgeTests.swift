import AppKit
import SwiftUI
import Testing
import AiTermUI
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The operator badge draws an `OperatorLine` (spec §7, §13, §14): one `Size.chip` line whatever it says,
/// quiet with no box, acting with no box and its words shimmering, needs-you in the attention chip's
/// pair, and on the selection the surface's wash and ink. The shimmer stands still under Reduce Motion and
/// in the snapshots.
@MainActor
struct OperatorBadgeTests {
    private func fitting(_ line: OperatorLine, width: CGFloat? = nil) -> CGSize {
        let host = NSHostingView(rootView: OperatorBadge(line: line).frame(width: width, alignment: .leading)
            .surface(.sidebar).environment(\.stillSpinners, true))
        return host.fittingSize
    }

    @Test func oneLineAlways() {
        let long = OperatorLine(String(repeating: "waiting on you · a very long question ", count: 4), look: .needsYou, oracle: true)
        for line in [long, OperatorLine("working"), OperatorLine("consulting the Oracle", look: .acting, oracle: true)] {
            #expect(fitting(line).height == Size.chip, "\(line.text)")
        }
        // Squeezed into a narrow column it cuts its words rather than wrap.
        #expect(fitting(long, width: 120).height == Size.chip)
    }

    @Test func stillUnderReduceMotion() {
        #expect(OperatorBadge.shimmers(.acting, reduceMotion: false, still: false))
        #expect(!OperatorBadge.shimmers(.acting, reduceMotion: true, still: false))
        #expect(!OperatorBadge.shimmers(.acting, reduceMotion: false, still: true))
        #expect(!OperatorBadge.shimmers(.quiet, reduceMotion: false, still: false))
        #expect(!OperatorBadge.shimmers(.needsYou, reduceMotion: false, still: false))
        // Standing still, acting is the surface's ink; quiet sits back in its secondary ink.
        for surface in [Surface.sidebar, .accent] {
            #expect(OperatorBadge.ink(.acting, surface: surface, shimmering: false) == surface.ink)
            #expect(OperatorBadge.ink(.acting, surface: surface, shimmering: true) == surface.secondaryInk)
            #expect(OperatorBadge.ink(.quiet, surface: surface, shimmering: false) == surface.secondaryInk)
        }
        // A still acting badge draws the same twice: nothing moves in a snapshot.
        let line = OperatorLine("answering Claude", look: .acting)
        let view = OperatorBadge(line: line).padding(Space.base).background(Palette.sidebar).surface(.sidebar)
        let first = Snapshots.png(of: Snapshot("badge.png") { view }), second = Snapshots.png(of: Snapshot("badge.png") { view })
        #expect(first != nil && first == second)
    }

    @Test func needsYouIsTheAttentionChipOffTheAccentAndTheWashOnIt() {
        #expect(OperatorBadge.box(.needsYou, surface: .sidebar) == .init(fill: Palette.statusChipAttentionFill, stroke: Palette.statusChipAttentionStroke))
        #expect(OperatorBadge.box(.needsYou, surface: .accent) == .init(fill: Surface.accent.badgeWash, stroke: nil))
        #expect(OperatorBadge.ink(.needsYou, surface: .sidebar, shimmering: false) == Palette.text)
        #expect(OperatorBadge.ink(.needsYou, surface: .accent, shimmering: false) == Surface.accent.ink)
        for surface in [Surface.sidebar, .accent] {
            #expect(OperatorBadge.box(.quiet, surface: surface) == nil)
            #expect(OperatorBadge.box(.acting, surface: surface) == nil, "acting has no box")
        }
    }

    @Test func theOracleJoinsTheOperatorsMarkOnlyWhileItIsConsulted() {
        #expect(OperatorBadge.marks(OperatorLine("merging", look: .acting)) == [.claude])
        #expect(OperatorBadge.marks(OperatorLine("consulting the Oracle", look: .acting, oracle: true)) == [.claude, .codex])
        #expect(OperatorBadge.marks(OperatorLine("consulting the Oracle", look: .acting, oracle: true, oracleAgent: .claude)) == [.claude, .claude])
        let one = fitting(OperatorLine("x")).width, two = fitting(OperatorLine("x", oracle: true)).width
        #expect(two - one == Size.inlineMark - Space.tight, "the Oracle's mark overlaps the Operator's by Space.tight")
    }

    /// The shimmer is Core Animation's: a gradient band swept across the words' mask on the layer, so over
    /// half a second (some thirty frames) the words' view is not updated once, and nothing shimmers when
    /// the badge stands still.
    @Test func theShimmerSweepsOnALayerWithoutAnUpdatePerFrame() throws {
        func hosted(_ view: some View) -> (NSWindow, NSView) {
            let host = NSHostingView(rootView: view.padding(Space.base).background(Palette.sidebar).surface(.sidebar))
            host.appearance = NSAppearance(named: .darkAqua)
            let window = testWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40), styleMask: [.borderless])
            window.contentView = host
            window.orderFrontRegardless()
            return (window, host)
        }
        let (window, host) = hosted(OperatorBadge(line: OperatorLine("consulting the Oracle", look: .acting, oracle: true)))
        defer { window.close() }
        settle(host) { host.firstDescendant(ShimmerWordsView.self) != nil }
        let words = try #require(host.firstDescendant(ShimmerWordsView.self))
        settle(host, for: 0.1)
        #expect(words.band.animation(forKey: ShimmerWordsView.sweepKey) != nil, "the band sweeps on Core Animation's clock")
        #expect(words.lit.mask === words.band)
        let before = OperatorBadge.shimmerUpdates
        settle(host, for: 0.5)
        #expect(OperatorBadge.shimmerUpdates - before == 0, "the words were updated \(OperatorBadge.shimmerUpdates - before) times in 0.5 s")

        // Standing still (a snapshot here; Reduce Motion takes the same path, `shimmers` above) there is no layer.
        let (still, stillHost) = hosted(OperatorBadge(line: OperatorLine("merging", look: .acting)).environment(\.stillSpinners, true))
        defer { still.close() }
        settle(stillHost, for: 0.1)
        #expect(stillHost.firstDescendant(ShimmerWordsView.self) == nil, "standing still, the words are SwiftUI's text")
    }
}
