import AppKit
import SwiftUI
import Testing
import AiTermCore
import AiTermUI
@testable import AiTerm

@MainActor
@Suite struct PiVendorMarkTests {
    @Test func piMarkUsesWhiteBadgeOnBlack() throws {
        let host = NSHostingView(rootView: VendorMark(agent: .pi, size: 40))
        host.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width

        // Sampled inside the badge's box as `LogoFit.pi` places it: the middle of the top bar
        // (viewBox x 0–420, y 0–140) is ink, and the corner beside it is the disc.
        let fit = LogoFit.pi, box = 40 * fit.scale
        let left = (40 - box) / 2 + 40 * fit.dx, top = (40 - box) / 2 + 40 * fit.dy
        #expect(isLight(pixelFromTop(bitmap, x: left + box * 0.375, y: top + box * 0.125, scale: scale)))
        #expect(isDark(pixelFromTop(bitmap, x: left + box * 0.875, y: top + box * 0.125, scale: scale)))
    }

    private func pixelFromTop(_ bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat, scale: CGFloat) -> NSColor? {
        let pixelX = min(bitmap.pixelsWide - 1, max(0, Int((x * scale).rounded(.down))))
        let pixelY = min(bitmap.pixelsHigh - 1, max(0, Int((y * scale).rounded(.down))))
        return bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB)
    }

    private func isDark(_ color: NSColor?) -> Bool {
        guard let color else { return false }
        return color.redComponent < 0.25 && color.greenComponent < 0.25 && color.blueComponent < 0.25
    }

    private func isLight(_ color: NSColor?) -> Bool {
        guard let color else { return false }
        return color.redComponent > 0.8 && color.greenComponent > 0.8 && color.blueComponent > 0.8
    }
}
