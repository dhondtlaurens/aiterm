import AppKit
import SwiftUI
import Testing
@testable import AiTermUI

@MainActor
struct PaletteTests {
    /// The grounds, darkest first, as the layered foundation stacks them (13 Nov 2026): the well, the
    /// sidebar footer, a field, the window, the sheet, a card, a popover, a button and a selected segment.
    private static let ramp: [(name: String, color: Color)] = [
        ("well", Palette.well), ("sidebarFooter", Palette.sidebarFooter), ("field", Palette.field), ("sidebar", Palette.sidebar),
        ("surface", Palette.surface), ("surfaceRaised", Palette.surfaceRaised), ("menu", Palette.menu),
        ("button", Palette.button), ("controlActive", Palette.controlActive),
    ]

    private static func resolved(_ color: Color, in name: NSAppearance.Name) throws -> NSColor {
        try #require(ColorProbe.resolved(color, in: name))
    }

    private static func lightness(_ color: NSColor) -> CGFloat {
        color.redComponent + color.greenComponent + color.blueComponent
    }

    /// Each ground is lighter than the one under it, in both appearances: a field is sunk below the
    /// window it sits on, a card lifts off the sheet, and the selected segment (`controlActive`) is
    /// the lightest of all, so a selection stands off the `field` track it sits in.
    @Test(arguments: [NSAppearance.Name.darkAqua, .accessibilityHighContrastDarkAqua])
    func theGroundsRiseInOrder(appearanceName: NSAppearance.Name) throws {
        let values = try Self.ramp.map { (name: $0.name, value: Self.lightness(try Self.resolved($0.color, in: appearanceName))) }
        for (lower, upper) in zip(values, values.dropFirst()) {
            #expect(lower.value < upper.value, "\(lower.name) is not darker than \(upper.name)")
        }
    }

    /// The grounds are graphite: a neutral grey with at most a faint cool cast, never a colour. The
    /// selected segment used to be AppKit's unemphasized selection, held to grey the same way.
    @Test(arguments: [NSAppearance.Name.darkAqua, .accessibilityHighContrastDarkAqua])
    func theGroundsAreGraphite(appearanceName: NSAppearance.Name) throws {
        for ground in Self.ramp {
            let color = try Self.resolved(ground.color, in: appearanceName)
            #expect(abs(color.redComponent - color.greenComponent) < 0.02, "\(ground.name)")
            #expect(color.blueComponent >= color.greenComponent, "\(ground.name) leans warm")
            #expect(color.blueComponent - color.redComponent < 0.05, "\(ground.name) is tinted, not graphite")
        }
    }

    /// Increase Contrast is written by hand: the inks and both hairlines take a stronger value of
    /// their own under it, and the grounds stay exactly as they are. Resolved through
    /// `IncreaseContrast.forced` (`ColorProbe`), since AppKit cannot be handed the appearance by name.
    @Test func increaseContrastStrengthensInksAndHairlinesButNotGrounds() throws {
        let strengthened: [(String, Color)] = [("text", Palette.text), ("muted", Palette.muted), ("tertiary", Palette.tertiary),
                                               ("border", Palette.border), ("borderStrong", Palette.borderStrong)]
        for (name, color) in strengthened {
            let standard = try Self.resolved(color, in: .darkAqua)
            let high = try Self.resolved(color, in: .accessibilityHighContrastDarkAqua)
            #expect(standard != high, "\(name) is the same under Increase Contrast")
            #expect(Self.lightness(high) * high.alphaComponent > Self.lightness(standard) * standard.alphaComponent,
                    "\(name) is not stronger under Increase Contrast")
        }
        for (name, color) in Self.ramp {
            #expect(ColorProbe.rgba(color) == ColorProbe.rgba(color, in: .accessibilityHighContrastDarkAqua),
                    "the \(name) ground changes under Increase Contrast")
        }
    }

    /// The live decision is AppKit's: the dark appearance, unforced, is not Increase Contrast, so
    /// the app draws the standard values unless the system asks for more.
    @Test func theDarkAppearanceTakesTheStandardValues() throws {
        #expect(!IncreaseContrast.isOn(in: try #require(NSAppearance(named: .darkAqua))))
        #expect(Icon.hexString(Palette.text) == "#ECEDEF")
    }

    /// `badge` is literal white at 6 %, not a share of `.primary`, which carries the label ink's own
    /// alpha and compounded with it. This pins what the wash is, so no one "corrects" it to a
    /// `.primary` share and silently dims every badge.
    @Test func theBadgeWashIsSixPercentWhite() throws {
        let badge = try Self.resolved(Palette.badge, in: .darkAqua)
        #expect(abs(badge.alphaComponent - 0.06) < 0.002)
        #expect(badge.redComponent > 0.99 && badge.greenComponent > 0.99 && badge.blueComponent > 0.99)
    }

    /// The firm hairline is firmer than the soft one, in both appearances: a field's outline holds
    /// against its darker well where a separator only has to part two rows.
    @Test(arguments: [NSAppearance.Name.darkAqua, .accessibilityHighContrastDarkAqua])
    func theFirmHairlineIsFirmer(appearanceName: NSAppearance.Name) throws {
        #expect(try Self.resolved(Palette.borderStrong, in: appearanceName).alphaComponent
                > Self.resolved(Palette.border, in: appearanceName).alphaComponent)
    }

    /// The placeholder is AppKit's own, so the prompt editor's overlaid hint matches what AppKit
    /// draws in every `Input` and `SearchField`.
    @Test func thePlaceholderIsAppKits() {
        #expect(ColorProbe.rgba(Palette.placeholder) == ColorProbe.rgba(Color(nsColor: .placeholderTextColor)))
    }
}
