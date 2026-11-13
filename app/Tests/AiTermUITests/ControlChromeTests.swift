import AiTermTestSupport
import AppKit
import SwiftUI
import Testing
@testable import AiTermUI

@MainActor
struct ControlChromeTests {
    /// A highlighted dropdown row is neutral (the layered foundation, 13 Nov 2026), so it declares
    /// the popup's own resting ground, highlighted or not: a ticket's mark keeps its brand colour and
    /// its key the link colour. Declared even inside a sidebar-declared view, so a popup there inks
    /// for itself.
    @Test func aHighlightedMenuRowKeepsTheRestingGround() {
        #expect(Self.surface(inside: { $0.menuRowHighlight(true) }) == .sheet)
        #expect(Self.surface(inside: { $0.menuRowHighlight(false, pressed: true) }) == .sheet)
        #expect(Self.surface(inside: { $0.menuRowHighlight(false) }) == .sheet)
    }

    /// The highlight itself is a grey wash, not the accent, and a press strengthens it.
    @Test func theHighlightIsANeutralWashThatAPressStrengthens() throws {
        func drawn(_ on: Bool, pressed: Bool = false) throws -> NSColor {
            try #require(brightestPixel(of: Color.clear.frame(width: 40, height: 20).menuRowHighlight(on, pressed: pressed)))
        }
        let highlighted = try drawn(true), pressed = try drawn(false, pressed: true)
        for pixel in [highlighted, pressed] {
            #expect(abs(pixel.redComponent - pixel.blueComponent) < 0.01, "the highlight is tinted: \(pixel)")
            #expect(pixel.redComponent > 0.03, "no highlight drawn")
        }
        #expect(pressed.redComponent > highlighted.redComponent)
    }

    private static func surface(inside wrap: (EnvironmentReader) -> some View) -> Surface? {
        let log = EnvironmentLog()
        let host = testHost(wrap(EnvironmentReader(log: log)).surface(.sidebar), size: CGSize(width: 40, height: 20))
        host.layoutSubtreeIfNeeded()
        return log.surface[0]
    }
}
