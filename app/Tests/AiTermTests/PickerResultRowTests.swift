import AppKit
import SwiftUI
import Testing
import AiTermUI
@testable import AiTerm

/// A picker's result row inks itself for the ground its row declares (`menuRowHighlight`), not for
/// a flag it is handed.
@MainActor
struct PickerResultRowTests {
    @Test func onTheAccentEveryForegroundIsWhite() throws {
        try expectWhite(try #require(PickerResultRow.logoTint(on: .accent)), opacity: 1)
        try expectWhite(PickerResultRow.keyInk(on: .accent), opacity: 1)
        try expectWhite(Surface.accent.ink, opacity: 1)
        try expectWhite(Surface.accent.secondaryInk, opacity: 0.75)
    }

    /// Off the accent — a highlighted dropdown row declares `.sheet`, and a selected row is neutral —
    /// the mark keeps its brand colour and the key the link colour.
    @Test func offTheAccentTheMarkAndKeyKeepTheirColours() {
        for surface in [Surface.sheet, .selected, .selectedOnSheet] {
            #expect(PickerResultRow.logoTint(on: surface) == nil, "\(surface)")
            #expect(PickerResultRow.keyInk(on: surface) == Palette.link, "\(surface)")
        }
    }

    private func expectWhite(_ color: Color, opacity: CGFloat) throws {
        let resolved = try #require(NSColor(color).usingColorSpace(.sRGB))
        #expect(abs(resolved.redComponent - 1) < 0.01)
        #expect(abs(resolved.greenComponent - 1) < 0.01)
        #expect(abs(resolved.blueComponent - 1) < 0.01)
        #expect(abs(resolved.alphaComponent - opacity) < 0.01)
    }
}
