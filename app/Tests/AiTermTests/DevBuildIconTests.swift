import AppKit
import Testing
@testable import AiTerm

@MainActor
@Suite struct DevBuildIconTests {
    /// Renders `image` into a 128 × 128 bitmap and returns the colour at a point measured from the
    /// bottom left, as fractions of the side.
    private func pixel(_ image: NSImage, x: Double, y: Double) -> NSColor {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: Int(x * 128), y: Int((1 - y) * 128))!.usingColorSpace(.deviceRGB)!
    }

    private let black = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
        NSColor.black.setFill(); rect.fill(); return true
    }

    @Test func thePillSitsAcrossTheBottomAndTheRestIsTheIcon() {
        let badged = DevBuildIcon.badged(black)
        #expect(badged.size == black.size)
        // The pill's left end, clear of the lettering: orange, so red well above blue.
        let pill = pixel(badged, x: 0.26, y: 0.14)
        #expect(pill.redComponent > 0.8 && pill.blueComponent < 0.3)
        // The top right, where the task count badge goes, is the icon untouched.
        let corner = pixel(badged, x: 0.85, y: 0.85)
        #expect(corner.redComponent < 0.05 && corner.greenComponent < 0.05 && corner.blueComponent < 0.05)
    }
}
