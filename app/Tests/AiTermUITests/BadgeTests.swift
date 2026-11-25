import AppKit
import Testing
import SwiftUI
@testable import AiTermUI

@MainActor
struct BadgeTests {
    @Test func theFillAnswersToTheSurface() {
        // Resting on the sidebar and resting on a selected row are different washes; the badge
        // reads that from the environment rather than taking a flag.
        #expect(Badge.fill(surface: .sidebar, hovered: false) == Palette.badge)
        #expect(Badge.fill(surface: .selected, hovered: false) == Palette.badgeSelected)
        #expect(Badge.fill(surface: .selectedOnSheet, hovered: false) == Palette.badgeSelected)
        #expect(Badge.fill(surface: .accent, hovered: false) == Palette.badgeSelected)
    }

    @Test func theFillStrengthensOnHover() {
        // Both buttons on a subtitle line answer to the pointer, on either surface.
        #expect(Badge.fill(surface: .sidebar, hovered: true) == Palette.badgeHovered)
        #expect(Badge.fill(surface: .selected, hovered: true) == Palette.badgeSelectedHovered)
        #expect(Badge.fill(surface: .accent, hovered: true) == Palette.badgeSelectedHovered)
    }

    @Test func aBoxedLabelTakesTheSurfaceInk() {
        #expect(Badge.labelInk(surface: .sidebar) == Surface.sidebar.ink)
        #expect(Badge.labelInk(surface: .selected) == Surface.selected.ink)
        #expect(Badge.labelInk(surface: .accent) == Surface.accent.ink)
    }

    @Test func theIconTintTurnsWhiteOnlyOnTheAccent() {
        // A brand mark keeps its own vendor colour off the accent (nil tint, `Icon` falls back to
        // `brand.hex`) — a selected row included, which is neutral — and turns plain white on the
        // accent, exactly like the label above.
        #expect(Badge.iconTint(surface: .sidebar) == nil)
        #expect(Badge.iconTint(surface: .hover) == nil)
        #expect(Badge.iconTint(surface: .selected) == nil)
        #expect(Badge.iconTint(surface: .selectedOnSheet) == nil)
        #expect(Badge.iconTint(surface: .sheet) == nil)
        #expect(Badge.iconTint(surface: .accent) == Palette.onAccent)
    }

    @Test func aStatusTintColoursTheIconOffTheAccentOnly() {
        // A Settings check chip inks its checkmark green or its warning amber, a selected row's
        // too. On the accent everything still turns white, so the override yields like the label does.
        #expect(Badge.iconTint(surface: .sheet, override: Palette.green) == Palette.green)
        #expect(Badge.iconTint(surface: .sidebar, override: Palette.amber) == Palette.amber)
        #expect(Badge.iconTint(surface: .selected, override: Palette.amber) == Palette.amber)
        #expect(Badge.iconTint(surface: .accent, override: Palette.green) == Palette.onAccent)
    }

    /// The sidebar's badge line inks its vendor marks with its words (`markInk: .label`): a quiet badge's
    /// secondary ink on every ground off the accent, a selected row's included, and white on the accent.
    /// Everywhere else the default `.own` keeps the brand's colour, and a check chip's override still wins.
    @Test func aMarkInkedWithItsLabelTakesTheQuietInk() {
        for surface in [Surface.sidebar, .hover, .selected, .washed] {
            #expect(Badge.iconTint(surface: surface, markInk: .label, style: .quiet) == surface.secondaryInk)
            #expect(Badge.iconTint(surface: surface, markInk: .own, style: .quiet) == nil, "brand colour by default")
        }
        #expect(Badge.iconTint(surface: .accent, markInk: .label, style: .quiet) == Palette.onAccent)
        #expect(Badge.iconTint(surface: .sidebar, override: Palette.green, markInk: .label, style: .quiet) == Palette.green)
        // The diff keeps its green and red beside a mark inked with its words.
        #expect(Badge.diffInk(surface: .sidebar, side: .added) == Palette.diffAdded)
        #expect(Badge.diffInk(surface: .sidebar, side: .removed) == Palette.diffRemoved)
    }

    @Test func aDiffReadsAsSignedCountsWithAnEmptySideLeftOut() {
        // The extended VS Code badge: `+12 −3`, a true minus sign rather than a hyphen. A side with
        // nothing to count is left out rather than drawn as `+0`, and a diff with neither side is
        // no diff at all — the badge falls back to its plain shape.
        #expect(Badge.Diff(added: 12, removed: 3).segments.map(\.text) == ["+12", "\u{2212}3"])
        #expect(Badge.Diff(added: 7, removed: 0).segments.map(\.text) == ["+7"])
        #expect(Badge.Diff(added: 0, removed: 4).segments.map(\.text) == ["\u{2212}4"])
        #expect(Badge.Diff(added: 0, removed: 0).isEmpty)
        #expect(!Badge.Diff(added: 1, removed: 0).isEmpty)
    }

    @Test func diffCountsAreGreenAndRedOffTheAccentOnly() {
        // Additions green, removals red, on every ground but the accent — a selected row included —
        // where, like the icon and the label, both turn the surface's own white.
        #expect(Badge.diffInk(surface: .sidebar, side: .added) == Palette.diffAdded)
        #expect(Badge.diffInk(surface: .hover, side: .removed) == Palette.diffRemoved)
        #expect(Badge.diffInk(surface: .selected, side: .added) == Palette.diffAdded)
        #expect(Badge.diffInk(surface: .selected, side: .removed) == Palette.diffRemoved)
        #expect(Badge.diffInk(surface: .accent, side: .added) == Surface.accent.ink)
        #expect(Badge.diffInk(surface: .accent, side: .removed) == Surface.accent.ink)
    }

    @Test func aQuietBadgeHasNoBoxUntilHovered() {
        // The sidebar rows' badges: no wash at rest, so the subtitle line reads as one line of text
        // rather than a row of boxes; under the pointer the same wash a boxed badge hovers to.
        #expect(Badge.fill(surface: .sidebar, hovered: false, style: .quiet) == .clear)
        #expect(Badge.fill(surface: .accent, hovered: false, style: .quiet) == .clear)
        #expect(Badge.fill(surface: .sidebar, hovered: true, style: .quiet) == Surface.sidebar.badgeWashHovered)
        #expect(Badge.fill(surface: .accent, hovered: true, style: .quiet) == Surface.accent.badgeWashHovered)
    }

    @Test func aQuietLabelTakesTheSecondaryInk() {
        // With no box behind it, the label sits back from the row title in secondary ink, on a
        // selected row and on the accent too.
        #expect(Badge.labelInk(surface: .sidebar, style: .quiet) == Surface.sidebar.secondaryInk)
        #expect(Badge.labelInk(surface: .selected, style: .quiet) == Palette.muted)
        #expect(Badge.labelInk(surface: .accent, style: .quiet) == Surface.accent.secondaryInk)
    }

    /// A badge in a scaled sidebar is a scaled chip: its height, padding and icon all grow together.
    @Test func aBadgeIsAChipAtItsScale() {
        for scale in InterfaceScale.all {
            let host = NSHostingView(rootView: Badge("SHOP-412", icon: .brand(Palette.jira)).fixedSize().interfaceScale(scale))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height == scale(Size.chip), "at ×\(scale.factor)")
        }
    }

    /// A diff is drawn whatever else the badge carries. With no icon it used to fall through every
    /// branch: a diff alone drew nothing, and a label beside it drew the label alone.
    @Test func aDiffIsDrawnWithoutAnIcon() {
        let diff = Badge.Diff(added: 12, removed: 3)
        #expect(Self.width(Badge(diff: diff)) > 0)
        #expect(Self.width(Badge("main", diff: diff)) > Self.width(Badge("main")))
    }

    /// A badge that opens a menu is the same chip as one that runs an action: the menu adds no
    /// bezel, no indicator and no padding of its own, at any scale.
    @Test func aMenuBadgeIsTheSameChipAsAButtonBadge() {
        for scale in InterfaceScale.all {
            let button = Self.size(Badge("3", icon: .brand(Palette.jira), style: .quiet, action: {}), scale)
            let menu = Self.size(Badge("3", icon: .brand(Palette.jira), style: .quiet, menu: { Button("SHOP — Storefront") {} }), scale)
            #expect(menu == button, "at ×\(scale.factor)")
        }
    }

    /// A suffix follows the label — a merge request's `[bubble] 2/5` — and a badge that is only an
    /// icon and a suffix is not drawn as an icon-only badge, which would leave the suffix out.
    @Test func aSuffixIsDrawnAfterTheLabelAndBesideALoneIcon() {
        let threads = Badge.Suffix(icon: .symbol("bubble.left"), text: "2/5")
        #expect(Self.width(Badge("!87", suffix: threads)) > Self.width(Badge("!87")))
        #expect(Self.width(Badge("!87", suffix: threads, style: .quiet)) > Self.width(Badge("!87", style: .quiet)))
        #expect(Self.width(Badge(icon: .brand(Palette.github), suffix: threads, style: .quiet))
                > Self.width(Badge(icon: .brand(Palette.github), style: .quiet)))
    }

    @Test(arguments: InterfaceScale.all)
    func anIconSuffixFollowsTheLabelOrHostWithOneGap(scale: InterfaceScale) throws {
        for label: String? in [nil, "!42"] {
            for ink in [Badge.MarkInk.label, .own] {
                let action: (() -> Void)? = label == nil ? nil : {}
                let plain = Badge(label, icon: .brand(Palette.gitlab), style: .quiet, markInk: ink)
                let merged = Badge(label, icon: .brand(Palette.gitlab), suffix: .init(icon: .joinedBranches),
                                   hoverChip: "Merged", style: .quiet, markInk: ink, action: action)
                let size = Self.size(merged, scale)
                #expect(abs(size.width - Self.size(plain, scale).width - scale(10) - scale(Space.tight)) < 1)
                #expect(size.height == scale(Size.chip))
                // In both ink modes the last 10 pt contain the same neutral ink.
                let host = NSHostingView(rootView: merged.surface(.sidebar).interfaceScale(scale))
                host.appearance = NSAppearance(named: .darkAqua)
                host.frame = CGRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let pointsToPixels = CGFloat(bitmap.pixelsWide) / size.width
                let glyphWidth = Int(scale(10) * pointsToPixels)
                var colors: [NSColor] = []
                for x in (bitmap.pixelsWide - glyphWidth)..<bitmap.pixelsWide {
                    for y in 0..<bitmap.pixelsHigh {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.75 {
                            colors.append(color)
                        }
                    }
                }
                let sample = try #require(colors.max { $0.alphaComponent < $1.alphaComponent })
                var expected: NSColor?
                host.effectiveAppearance.performAsCurrentDrawingAppearance {
                    expected = NSColor(Badge.labelInk(surface: .sidebar, style: .quiet)).usingColorSpace(.sRGB)
                }
                let inkColor = try #require(expected)
                #expect(abs(sample.redComponent - inkColor.redComponent) < 0.03)
                #expect(abs(sample.greenComponent - inkColor.greenComponent) < 0.03)
                #expect(abs(sample.blueComponent - inkColor.blueComponent) < 0.03)
            }
        }
    }

    /// A suffix keeps the badge a chip: no taller, at any scale.
    @Test func aBadgeWithASuffixIsStillAChipAtItsScale() {
        for scale in InterfaceScale.all {
            let badge = Badge("!87", icon: .brand(Palette.github), suffix: .init(icon: .symbol("bubble.left"), text: "6/6"), style: .quiet)
            let host = NSHostingView(rootView: badge.fixedSize().interfaceScale(scale))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height == scale(Size.chip), "at ×\(scale.factor)")
        }
    }

    /// The corner mark is drawn over the icon, never beside it: a badge wearing the check is the same
    /// chip, the same width and height, as one without at every scale, so the badge line does not move
    /// when a ticket is done or a request is approved.
    @Test func aBadgeWithACornerMarkIsTheSameChipAsOneWithout() {
        for scale in InterfaceScale.all {
            let threads = Badge.Suffix(icon: .symbol("bubble.left"), text: "4/4")
            #expect(Self.size(Badge("!81", icon: .brand(Palette.gitlab), suffix: threads, corner: .finished, style: .quiet), scale)
                    == Self.size(Badge("!81", icon: .brand(Palette.gitlab), suffix: threads, style: .quiet), scale), "at ×\(scale.factor)")
            #expect(Self.size(Badge(icon: .brand(Palette.jira), corner: .finished, style: .quiet), scale)
                    == Self.size(Badge(icon: .brand(Palette.jira), style: .quiet), scale), "at ×\(scale.factor)")
        }
    }

    private static func width(_ badge: Badge) -> CGFloat {
        let host = NSHostingView(rootView: badge)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    private static func size(_ badge: Badge, _ scale: InterfaceScale) -> CGSize {
        let host = NSHostingView(rootView: badge.interfaceScale(scale))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
