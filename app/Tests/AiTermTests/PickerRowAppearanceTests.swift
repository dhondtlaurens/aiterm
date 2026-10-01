import AppKit
import SwiftUI
import Testing
import AiTermUI
@testable import AiTerm

@MainActor
struct PickerRowAppearanceTests {
    @Test func aSelectedResultRowUsesWhiteForegrounds() throws {
        let appearance = PickerRowAppearance(selected: true)

        try expectWhite(try #require(appearance.logoTint), opacity: 1)
        try expectWhite(appearance.keyColor, opacity: 1)
        try expectWhite(appearance.titleColor, opacity: 1)
        try expectWhite(appearance.detailColor, opacity: 0.75)
    }

    @Test func anUnselectedRowKeepsItsBrandColour() {
        #expect(PickerRowAppearance(selected: false).logoTint == nil)
    }

    private func expectWhite(_ color: Color, opacity: CGFloat) throws {
        let resolved = try #require(NSColor(color).usingColorSpace(.sRGB))
        #expect(abs(resolved.redComponent - 1) < 0.01)
        #expect(abs(resolved.greenComponent - 1) < 0.01)
        #expect(abs(resolved.blueComponent - 1) < 0.01)
        #expect(abs(resolved.alphaComponent - opacity) < 0.01)
    }
}
