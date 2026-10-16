import AppKit
import SwiftUI
import Testing
import AiTermUI
@testable import AiTermCore
@testable import AiTerm

/// The operator's mark is the same `.paper` disc for every operator; only while it acts on a task does
/// it wear the accent ring, which breathes — and stands still under Reduce Motion and in a snapshot.
@MainActor
struct OperatorAvatarTests {
    /// The accent as this Mac draws it, dark: `Palette.accent` is `controlAccentColor`, which follows
    /// the accent picked in System Settings — blue, purple, graphite… — so the test reads it rather than
    /// assuming blue.
    private func accent() throws -> NSColor {
        var resolved: NSColor?
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            resolved = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        }
        return try #require(resolved)
    }

    /// How many pixels `view` draws within a small tolerance of the accent: the ring's ink. The mark is
    /// black on white and the occluding ring the sidebar's grey; a graphite accent may share a few edge
    /// pixels with those, so the tests compare an acting mark with a driving one rather than with zero.
    private func accentPixels(_ view: some View) throws -> Int {
        let accent = try accent()
        let host = NSHostingView(rootView: view.padding(Space.base).background(Palette.sidebar)
            .surface(.sidebar).environment(\.stillSpinners, true))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var count = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - accent.redComponent) < 0.1, abs(c.greenComponent - accent.greenComponent) < 0.1,
                   abs(c.blueComponent - accent.blueComponent) < 0.1 { count += 1 }
            }
        }
        return count
    }

    @Test func onlyAnActingOperatorWearsTheAccentRing() throws {
        let driving = try accentPixels(OperatorAvatar(presence: .driving, size: Size.avatar))
        let acting = try accentPixels(OperatorAvatar(presence: .acting, size: Size.avatar))
        #expect(acting > driving + 20, "acting \(acting) accent pixels, driving \(driving)")
    }

    @Test func theRingBreathesOnlyWhileActingAndNeverUnderReduceMotion() {
        #expect(OperatorAvatar.breathes(.acting, reduceMotion: false, still: false))
        #expect(!OperatorAvatar.breathes(.acting, reduceMotion: true, still: false))
        #expect(!OperatorAvatar.breathes(.acting, reduceMotion: false, still: true))
        #expect(!OperatorAvatar.breathes(.driving, reduceMotion: false, still: false))
        #expect(OperatorAvatar.symbol == "headphones")
    }

    @Test func theOperatorLeadsTheAvatarGroupAndStillTakesTwoPlaces() throws {
        func width(_ group: AvatarGroup) -> CGFloat {
            let host = NSHostingView(rootView: AvatarGroupView(group: group).surface(.sidebar))
            return host.fittingSize.width
        }
        #expect(width(AvatarGroup(marks: [.claude], overflow: 0, operatorPresence: .acting))
                == width(AvatarGroup(marks: [.claude, .codex], overflow: 0)), "the column stays two marks wide")
        let acting = try accentPixels(AvatarGroupView(group: AvatarGroup(marks: [.claude], overflow: 0, operatorPresence: .acting)))
        let driving = try accentPixels(AvatarGroupView(group: AvatarGroup(marks: [.claude], overflow: 0, operatorPresence: .driving)))
        #expect(acting > driving + 20, "the group draws the acting operator's ring")
    }
}
