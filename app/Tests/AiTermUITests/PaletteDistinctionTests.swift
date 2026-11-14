import SwiftUI
import Testing
import Foundation
@testable import AiTermUI

/// After the 4b unification, two `Palette` members that are written differently must not resolve
/// to the same value — that is precisely the defect 6d0c853 introduced. Members that are *written*
/// as aliases (`codeBackground = well`) are exempt: they declare their sameness honestly.
@MainActor
struct PaletteDistinctionTests {
    /// Every semantic colour `Palette` declares, by its Swift name. Kept here rather than generated:
    /// there is no token exporter to keep in sync with `Palette.swift`, so this list is this test's
    /// own responsibility — add a member there, add its line here.
    /// `everyPaletteColourIsInTheManifest` below fails the build if you forget. Aliases and vendor
    /// marks need nothing more: both are read from the source.
    private static let colors: [(name: String, color: Color)] = [
        ("well", Palette.well),
        ("codeBackground", Palette.codeBackground),
        ("field", Palette.field),
        ("sidebar", Palette.sidebar),
        ("sidebarFooter", Palette.sidebarFooter),
        ("surface", Palette.surface),
        ("surfaceRaised", Palette.surfaceRaised),
        ("menu", Palette.menu),
        ("button", Palette.button),
        ("controlActive", Palette.controlActive),
        ("text", Palette.text),
        ("muted", Palette.muted),
        ("tertiary", Palette.tertiary),
        ("border", Palette.border),
        ("borderStrong", Palette.borderStrong),
        ("accent", Palette.accent),
        ("focusRing", Palette.focusRing),
        ("focusEdge", Palette.focusEdge),
        ("link", Palette.link),
        ("green", Palette.green),
        ("amber", Palette.amber),
        ("destructive", Palette.destructive),
        ("badgeAmber", Palette.badgeAmber),
        ("diffAdded", Palette.diffAdded),
        ("diffRemoved", Palette.diffRemoved),
        ("devBuild", Palette.devBuild),
        ("devBuildInk", Palette.devBuildInk),
        ("onAccent", Palette.onAccent),
        ("onAccentSecondary", Palette.onAccentSecondary),
        ("spinnerTrackOnAccent", Palette.spinnerTrackOnAccent),
        ("keycapFill", Palette.keycapFill),
        ("keycapStroke", Palette.keycapStroke),
        ("accentPressed", Palette.accentPressed),
        ("placeholder", Palette.placeholder),
        ("faint", Palette.faint),
        ("markPaper", Palette.markPaper),
        ("markInk", Palette.markInk),
        ("selected", Palette.selected),
        ("selectedEdge", Palette.selectedEdge),
        ("selectedSolid", Palette.selectedSolid),
        ("selectedOnSheetSolid", Palette.selectedOnSheetSolid),
        ("badge", Palette.badge),
        ("badgeSelected", Palette.badgeSelected),
        ("badgeHovered", Palette.badgeHovered),
        ("badgeSelectedHovered", Palette.badgeSelectedHovered),
        ("menuHighlight", Palette.menuHighlight),
        ("menuHighlightPressed", Palette.menuHighlightPressed),
        ("rowHover", Palette.rowHover),
        ("rowHoverSolid", Palette.rowHoverSolid),
        ("rowHoverOnSheetSolid", Palette.rowHoverOnSheetSolid),
        ("operatorRow", Palette.operatorRow),
        ("operatorRowSolid", Palette.operatorRowSolid),
        ("operatorRowHoveredSolid", Palette.operatorRowHoveredSolid),
        ("statusChipQuietFill", Palette.statusChipQuietFill),
        ("statusChipQuietStroke", Palette.statusChipQuietStroke),
        ("statusChipAttentionFill", Palette.statusChipAttentionFill),
        ("statusChipAttentionStroke", Palette.statusChipAttentionStroke),
        ("statusChipDoneFill", Palette.statusChipDoneFill),
        ("statusChipDoneStroke", Palette.statusChipDoneStroke),
        ("idleRing", Palette.idleRing),
        ("spinnerTrack", Palette.spinnerTrack),
        ("spinner", Palette.spinner),
        ("done", Palette.done),
    ]

    /// `Palette`'s body, as written. The scan was ported from the deleted `DesignTokensTests` (see
    /// `git show e4622b6:app/Tests/AiTermUITests/DesignTokensTests.swift`).
    private static func paletteBody() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AiTermUI/Palette.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: "enum Palette {") else {
            Issue.record("no enum Palette in Palette.swift"); return ""
        }
        var depth = 0
        var body = ""
        for ch in source[start.lowerBound...] {
            if ch == "{" { depth += 1 }
            if ch == "}" { depth -= 1; if depth == 0 { break } }
            body.append(ch)
        }
        return body
    }

    /// The captures of `pattern` on each line of `body` it matches: the name, and the second group
    /// if the pattern has one.
    private static func captures(_ pattern: String, in body: String) throws -> [(name: String, target: String?)] {
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        return regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap { match in
            func group(_ index: Int) -> String? {
                index < match.numberOfRanges ? Range(match.range(at: index), in: body).map { String(body[$0]) } : nil
            }
            return group(1).map { (name: $0, target: group(2)) }
        }
    }

    /// Every `static let`/`static var` declared directly in `Palette` — `var` too, so a computed
    /// member added later is not missed.
    private static func members(in body: String) throws -> Set<String> {
        Set(try captures(#"static (?:let|var) (\w+)"#, in: body).map(\.name))
    }

    /// The members written as another member's name — `codeBackground = well` — which declare their
    /// sameness in the source and so are exempt from the distinctness check. Read from the source,
    /// so declaring an alias there is the whole of the work.
    private static func aliases(in body: String) throws -> Set<String> {
        let declared = try members(in: body)
        return Set(try captures(#"static let (\w+) = (\w+)$"#, in: body)
            .filter { $0.target.map(declared.contains) == true }.map(\.name))
    }

    /// The vendor marks: members declared as a `Brand(…)`, not a colour. Exempt from both the
    /// manifest and the distinctness check.
    private static func brandMarks(in body: String) throws -> Set<String> {
        Set(try captures(#"static let (\w+) = Brand\("#, in: body).map(\.name))
    }

    /// The guard `colors` above depends on: without this, a `Palette` member added without a line
    /// here just silently never gets checked for a collision — which is exactly the hover-halo
    /// defect (6d0c853) `everyDistinctNameMeansADistinctValue` exists to catch. This is what
    /// `app/Sources/AiTermUI/README.md` means when it says "`PaletteDistinctionTests` fails the
    /// build otherwise."
    @Test func everyPaletteColourIsInTheManifest() throws {
        let body = try Self.paletteBody()
        let declared = try Self.members(in: body).subtracting(Self.brandMarks(in: body))
        let listed = Set(Self.colors.map(\.name))
        #expect(declared.subtracting(listed).isEmpty,
                "Palette members missing from PaletteDistinctionTests.colors: \(declared.subtracting(listed).sorted())")
        #expect(listed.subtracting(declared).isEmpty,
                "PaletteDistinctionTests.colors lists what Palette does not declare: \(listed.subtracting(declared).sorted())")
    }

    /// A token's value is what it resolves to in both appearances AiTerm draws in: the dark one and
    /// Increase Contrast's. Two tokens that agree in the first but not the second — the firm hairline
    /// and a hovered badge's wash, both 12 % white until Increase Contrast strengthens the hairline —
    /// are different colours, and are not an accident to catch.
    @Test func everyDistinctNameMeansADistinctValue() throws {
        let aliases = try Self.aliases(in: Self.paletteBody())
        var byValue: [String: [String]] = [:]
        for token in Self.colors where !aliases.contains(token.name) {
            let value = ColorProbe.rgba(token.color) + " / " + ColorProbe.rgba(token.color, in: .accessibilityHighContrastDarkAqua)
            byValue[value, default: []].append(token.name)
        }
        let collisions = byValue.filter { $0.value.count > 1 }
        let description = collisions.map { "\($0.value.sorted().joined(separator: " == ")) → \($0.key)" }
                                     .sorted().joined(separator: "; ")
        #expect(collisions.isEmpty,
                "these resolve identically but are written as different colours: \(description)")
    }

    /// The scans above read the source. This pins what they read, so a change to how `Palette` is
    /// written that the patterns no longer match fails here, by name, rather than as a baffling
    /// collision or a missing member.
    @Test func theScansFindTheAliasesAndTheMarks() throws {
        let body = try Self.paletteBody()
        let aliases = try Self.aliases(in: body)
        #expect(aliases.isSuperset(of: ["codeBackground", "devBuildInk", "idleRing", "selectedEdge", "focusEdge"]))
        // The sidebar, the popover and the Operator's wash are grounds and washes of their own now,
        // no longer the sheet's, the card's and the badge's.
        for distinct in ["surface", "sidebar", "menu", "operatorRow", "onAccentSecondary"] {
            #expect(!aliases.contains(distinct), "\(distinct) is read as an alias")
        }
        #expect(try Self.brandMarks(in: body).isSuperset(of: ["claude", "jira", "gitlab", "github", "vscode"]))
    }

    /// `rowHoverSolid` exists because a wash can't correctly occlude what's behind it — it has to be
    /// the opaque composite of `rowHover` painted over `sidebar`. This measures that relationship
    /// through `ColorProbe`, to one 8-bit step per channel, so a hardcoded or stale `rowHoverSolid`
    /// fails here rather than only showing up as a hover halo. Every other solid is on the same
    /// rule over its own ground: the Operator row's rings at rest and hovered and a selected row's
    /// over the sidebar, a selected Archive row's over the sheet, a hovered board card over the card.
    ///
    /// Both sides are resolved live, in-process, through `ColorProbe` — never against a literal
    /// hex — so what is pinned is the relationship: each solid tracks its wash composited over its
    /// ground, whatever the ground's number becomes.
    @Test(arguments: [("rowHoverSolid", Palette.rowHoverSolid, Palette.rowHover, Palette.sidebar),
                      ("rowHoverOnSheetSolid", Palette.rowHoverOnSheetSolid, Palette.rowHover, Palette.surface),
                      ("operatorRowSolid", Palette.operatorRowSolid, Palette.operatorRow, Palette.sidebar),
                      ("operatorRowHoveredSolid", Palette.operatorRowHoveredSolid, Palette.badgeHovered, Palette.sidebar),
                      ("selectedSolid", Palette.selectedSolid, Palette.selected, Palette.sidebar),
                      ("selectedOnSheetSolid", Palette.selectedOnSheetSolid, Palette.selected, Palette.surface)])
    func aSolidIsItsWashCompositedOverItsGround(name: String, solid: Color, wash: Color, ground: Color) {
        expectComposite(solid, of: wash, over: ground, named: name)
    }

    private func expectComposite(_ solid: Color, of washColor: Color, over ground: Color, named name: String) {
        func components(_ rgba: String) -> (r: Double, g: Double, b: Double, a: Double) {
            let inner = rgba.trimmingCharacters(in: CharacterSet(charactersIn: "rgba() "))
            let parts = inner.split(separator: ",").map {
                Double($0.trimmingCharacters(in: .whitespaces)) ?? 0
            }
            return (parts[0], parts[1], parts[2], parts[3])
        }
        func channel(_ hex: String, _ index: Int) -> Int {
            let start = hex.index(hex.startIndex, offsetBy: 1 + index * 2)
            let end = hex.index(start, offsetBy: 2)
            return Int(hex[start..<end], radix: 16) ?? 0
        }

        let wash = components(ColorProbe.rgba(washColor))
        let base = components(ColorProbe.rgba(ground))
        let alpha = wash.a

        func blended(_ washChannel: Double, _ baseChannel: Double) -> Int {
            Int((washChannel * alpha + baseChannel * (1 - alpha)).rounded())
        }
        let expected = (r: blended(wash.r, base.r), g: blended(wash.g, base.g), b: blended(wash.b, base.b))

        let actualHex = Icon.hexString(solid)
        let actual = (r: channel(actualHex, 0), g: channel(actualHex, 1), b: channel(actualHex, 2))

        #expect(abs(actual.r - expected.r) <= 1,
                "\(name) (\(actualHex)) red channel \(actual.r) is not its wash composited over its ground (expected \(expected.r))")
        #expect(abs(actual.g - expected.g) <= 1,
                "\(name) (\(actualHex)) green channel \(actual.g) is not its wash composited over its ground (expected \(expected.g))")
        #expect(abs(actual.b - expected.b) <= 1,
                "\(name) (\(actualHex)) blue channel \(actual.b) is not its wash composited over its ground (expected \(expected.b))")
    }
}
