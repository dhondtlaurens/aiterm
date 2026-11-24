import AppKit
import SwiftUI
import Testing
@testable import AiTermUI

/// The chip raised above what the pointer is over: `Size.chip` tall at every size, at its own width, and raised
/// above its view without moving it, there only while shown.
@MainActor
struct HoverChipTests {
    @Test(arguments: InterfaceScale.all)
    func theChipIsSizeChipTallAtItsOwnWidth(scale: InterfaceScale) {
        let host = NSHostingView(rootView: HoverChip("Approved").interfaceScale(scale))
        #expect(abs(host.fittingSize.height - scale(Size.chip)) < 0.5)
        let words = ("Approved" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width * scale.factor
        #expect(host.fittingSize.width > words, "the chip is \(host.fittingSize.width) pt; its words alone are \(words) pt")
    }

    /// Raising the chip lays nothing out: the view keeps its own size whether or not the chip is up.
    @Test func raisingTheChipDoesNotMoveItsView() {
        func size(shown: Bool) -> CGSize {
            NSHostingView(rootView: Color.clear.frame(width: 30, height: 16)
                .raisingHoverChip(HoverChip("Merged"), shown: shown)).fittingSize
        }
        #expect(size(shown: true) == CGSize(width: 30, height: 16))
        #expect(size(shown: false) == CGSize(width: 30, height: 16))
    }

    /// Shown, the chip's ground is drawn above the view, its foot `Space.hairline` clear of the view's head and its
    /// leading edge on the view's; hidden, nothing is.
    @Test func theChipSitsAboveItsViewOnlyWhileShown() throws {
        func drawn(shown: Bool) throws -> NSBitmapImageRep {
            let host = NSHostingView(rootView: Color.clear.frame(width: 60, height: 16)
                .raisingHoverChip(HoverChip("Merged"), shown: shown)
                .padding(.top, 30).frame(width: 100, height: 46, alignment: .topLeading)
                .background(Palette.sidebar))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(x: 0, y: 0, width: 100, height: 46)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap
        }
        func ground(_ bitmap: NSBitmapImageRep) throws -> NSColor {
            // Inside the chip, between its leading edge and its words: 30 − hairline − chip/2 from the top.
            let factor = CGFloat(bitmap.pixelsWide) / 100
            let y = (30 - Space.hairline - Size.chip / 2) * factor
            return try #require(bitmap.colorAt(x: Int(2 * factor), y: Int(y))?.usingColorSpace(.sRGB))
        }
        func resolved(_ color: Color) throws -> NSColor {
            var out: NSColor?
            try #require(NSAppearance(named: .darkAqua)).performAsCurrentDrawingAppearance {
                out = NSColor(color).usingColorSpace(.sRGB)
            }
            return try #require(out)
        }
        func near(_ a: NSColor, _ b: NSColor) -> Bool {
            abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                + abs(a.blueComponent - b.blueComponent) < 0.04
        }
        #expect(near(try ground(drawn(shown: true)), try resolved(Palette.menu)))
        #expect(near(try ground(drawn(shown: false)), try resolved(Palette.sidebar)))
    }
}
