import AppKit
import SwiftUI
import Testing
import AiTermUI
@testable import AiTerm

/// The Notice (spec §6.1, §13): an amber mark carries the tone and the words stay ink. Read off the
/// rendered pixels, since the rule is about what is drawn: a longer title adds ink, never amber.
@MainActor
struct NoticeTests {
    /// `view` drawn dark on the sidebar's ground, as the banner draws it.
    private func bitmap(_ view: some View) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.padding(Space.base).background(Palette.sidebar).surface(.sidebar))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    /// `color` as it lands on the sidebar's ground: `Palette.text` is the label colour, which is
    /// translucent, so it is read off a drawn swatch rather than resolved.
    private func drawn(_ color: Color) throws -> NSColor {
        let swatch = try bitmap(Rectangle().fill(color).frame(width: Size.slot, height: Size.slot))
        return try #require(swatch.colorAt(x: swatch.pixelsWide / 2, y: swatch.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }

    private func count(_ color: NSColor, in bitmap: NSBitmapImageRep, within tolerance: CGFloat = 0.06) -> Int {
        var count = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - color.redComponent) < tolerance, abs(c.greenComponent - color.greenComponent) < tolerance,
                   abs(c.blueComponent - color.blueComponent) < tolerance { count += 1 }
            }
        }
        return count
    }

    @Test func drawsAndHasNoAmberText() throws {
        let ink = try drawn(Palette.text), amber = try drawn(Palette.amber)
        let short = try bitmap(Notice(title: "Pull stopped.", description: nil) { EmptyView() })
        let long = try bitmap(Notice(title: "Pull main stopped: main has diverged from origin’s main.", description: nil) { EmptyView() })
        let shortAmber = count(amber, in: short), longAmber = count(amber, in: long)
        #expect(shortAmber > 20, "the mark is amber: \(shortAmber) pixels")
        #expect(abs(longAmber - shortAmber) <= 4, "a longer title adds no amber: \(shortAmber) then \(longAmber)")
        let shortInk = count(ink, in: short), longInk = count(ink, in: long)
        #expect(shortInk > 20, "the title is in Palette.text: \(shortInk) pixels")
        #expect(longInk > shortInk * 2, "a longer title adds ink: \(shortInk) then \(longInk)")
    }

    /// The description is muted, never the title's ink or amber; actions are links under it.
    @Test func theDescriptionIsMuted() throws {
        let ink = try drawn(Palette.text), amber = try drawn(Palette.amber)
        let bare = try bitmap(Notice(title: "Pull stopped.", description: nil) { EmptyView() })
        let described = try bitmap(Notice(title: "Pull stopped.",
                                          description: "main has 2 commits origin doesn’t, and origin has 5 it doesn’t.") { EmptyView() })
        #expect(abs(count(amber, in: described) - count(amber, in: bare)) <= 4)
        #expect(abs(count(ink, in: described) - count(ink, in: bare)) <= 8, "the description adds no title ink")
        #expect(described.pixelsHigh > bare.pixelsHigh)
    }
}
