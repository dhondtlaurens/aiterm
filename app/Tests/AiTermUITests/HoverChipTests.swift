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

    /// Both edges of the chip can overhang its target. Measure its painted bounds with room on each side.
    @Test(arguments: InterfaceScale.all, [CGFloat(16), CGFloat(80)])
    func theChipCentersOverItsTarget(scale: InterfaceScale, width: CGFloat) throws {
        let top: CGFloat = 40, leading: CGFloat = 36
        let bounds = CGRect(x: 0, y: 0, width: 160, height: 60)
        func capture(shown: Bool) throws -> NSBitmapImageRep {
            let host = NSHostingView(rootView: Color.clear.frame(width: width, height: 16)
                .raisingHoverChip(HoverChip("Merged"), shown: shown)
                .padding(.leading, leading).padding(.top, top)
                .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
                .background(Palette.sidebar).interfaceScale(scale))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = bounds
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: bounds))
            host.cacheDisplay(in: bounds, to: bitmap)
            return bitmap
        }
        let bitmap = try capture(shown: true)
        let hidden = try capture(shown: false)
        let factor = CGFloat(bitmap.pixelsWide) / bounds.width
        let y = Int((top - scale(Space.hairline) - scale(Size.chip) / 2) * factor)
        let background = try #require(bitmap.colorAt(x: 0, y: y))
        #expect((0..<hidden.pixelsWide).allSatisfy { hidden.colorAt(x: $0, y: y) == background })
        let span = (0..<bitmap.pixelsWide).filter { bitmap.colorAt(x: $0, y: y) != background }
        let left = try #require(span.first), right = try #require(span.last)
        #expect(abs(CGFloat(left + right + 1) / (2 * factor) - (leading + width / 2)) <= 1)
        let middle = (left + right) / 2
        let bottom = try #require((0..<bitmap.pixelsHigh).last { bitmap.colorAt(x: middle, y: $0) != background })
        #expect(abs(top - CGFloat(bottom + 1) / factor - scale(Space.hairline)) <= 1)
    }
}
