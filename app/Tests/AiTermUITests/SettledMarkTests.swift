import AppKit
import SwiftUI
import Testing
@testable import AiTermUI

/// The settled marks: a filled disc for a state that holds until something outside changes it. Finished is the green
/// disc with a white check, paused the idle ring's disc with its bars cut out in the ground; on the accent, the disc
/// turns white and its glyph is cut out of it.
@MainActor
struct SettledMarkTests {
    private let size: CGFloat = 40

    private func drawn(_ kind: SettledMark.Kind, on surface: Surface = .sidebar) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: AnyView(SettledMark(kind, size: size).surface(surface)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: CGSize(width: size, height: size))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    /// The pixel at `x`, `y` in proportions of the mark's box, from its top-leading corner.
    private func pixel(_ bitmap: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) throws -> NSColor {
        let side = CGFloat(bitmap.pixelsWide)
        return try #require(bitmap.colorAt(x: Int(side * x), y: Int(side * y))?.usingColorSpace(.sRGB))
    }

    private func matches(_ pixel: NSColor, _ color: Color) throws -> Bool {
        var resolved: NSColor?
        try #require(NSAppearance(named: .darkAqua)).performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        let expected = try #require(resolved)
        return abs(pixel.redComponent - expected.redComponent) + abs(pixel.greenComponent - expected.greenComponent)
            + abs(pixel.blueComponent - expected.blueComponent) < 0.08
    }

    @Test func theMarkIsTheSizeItIsGiven() {
        let host = NSHostingView(rootView: SettledMark(.paused, size: Size.trailingGlyph))
        #expect(abs(host.fittingSize.width - Size.trailingGlyph) < 0.5 && abs(host.fittingSize.height - Size.trailingGlyph) < 0.5)
    }

    @Test func finishedIsAGreenDiscWithAWhiteCheck() throws {
        let bitmap = try drawn(.finished)
        #expect(try matches(pixel(bitmap, 0.5, 0.2), Palette.green), "the disc, above the check")
        #expect(try matches(pixel(bitmap, 0.59, 0.515), Palette.onAccent), "the check's long stroke")
    }

    @Test func pausedIsTheIdleRingsDiscWithItsBarsCutOutInTheGround() throws {
        for surface in [Surface.sidebar, .washed, .selected] {
            let bitmap = try drawn(.paused, on: surface)
            #expect(try matches(pixel(bitmap, 0.5, 0.5), Palette.idleRing), "between the bars, \(surface)")
            #expect(try matches(pixel(bitmap, 0.375, 0.5), surface.occludingBackground), "a bar, \(surface)")
        }
    }

    @Test func onTheAccentTheDiscTurnsWhiteAndItsGlyphIsCutOut() throws {
        let finished = try drawn(.finished, on: .accent), paused = try drawn(.paused, on: .accent)
        #expect(try matches(pixel(finished, 0.5, 0.2), Palette.onAccent))
        #expect(try matches(pixel(finished, 0.59, 0.515), Palette.accent))
        #expect(try matches(pixel(paused, 0.5, 0.5), Palette.onAccent))
        #expect(try matches(pixel(paused, 0.375, 0.5), Palette.accent))
    }
}
