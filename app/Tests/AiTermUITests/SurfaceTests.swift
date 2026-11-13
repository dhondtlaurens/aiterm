import Testing
import SwiftUI
@testable import AiTermUI

@MainActor
struct SurfaceTests {
    private static let every: [Surface] = [.sidebar, .hover, .washed, .washedHover, .selected, .selectedOnSheet, .accent, .sheet]

    @Test func accentSurfaceInksWhite() {
        // On the accent — a primary button's label — every mark and label turns
        // white: a brand colour or a grey label on the accent reads as a bug.
        #expect(Icon.hexString(Surface.accent.ink) == "#FFFFFF")
        #expect(Surface.accent.isOnAccent)
    }

    /// A selected row is neutral (the layered foundation, 13 Nov 2026): its title lifts to full
    /// white, its secondary ink stays the resting `muted`, and it is not the accent, so every mark on
    /// it keeps its own colour.
    @Test func aSelectedRowLiftsItsTitleAndKeepsEverythingElse() {
        for surface in [Surface.selected, .selectedOnSheet] {
            #expect(Icon.hexString(surface.ink) == "#FFFFFF")
            #expect(ColorProbe.rgba(surface.secondaryInk) == ColorProbe.rgba(Palette.muted))
            #expect(!surface.isOnAccent)
            #expect(surface.isSelected)
        }
        for surface in Self.every where surface != .selected && surface != .selectedOnSheet {
            #expect(!surface.isSelected, "\(surface)")
        }
    }

    @Test func restingSurfacesUseThePaletteInk() {
        for surface in [Surface.sidebar, .hover, .sheet] {
            #expect(ColorProbe.rgba(surface.ink) == ColorProbe.rgba(Palette.text))
            #expect(!surface.isOnAccent)
        }
    }

    @Test func theBadgeWashStrengthensOnASelectedRowAndTheAccent() {
        // The wash has to read against whatever is behind it: 6 % white at rest, 11 % on the
        // lighter selected row and on the accent. Getting this backwards makes a badge vanish on a
        // selected row.
        let resting = ColorProbe.alpha(Surface.sidebar.badgeWash)
        for surface in [Surface.selected, .selectedOnSheet, .accent] {
            #expect(ColorProbe.alpha(surface.badgeWash) > resting, "the wash must strengthen on \(surface), not weaken")
            #expect(ColorProbe.rgba(surface.badgeWash) == ColorProbe.rgba(Palette.badgeSelected))
            #expect(ColorProbe.rgba(surface.badgeWashHovered) == ColorProbe.rgba(Palette.badgeSelectedHovered))
        }
    }

    @Test func hoverStrengthensEveryWash() {
        for surface in Self.every {
            #expect(ColorProbe.alpha(surface.badgeWashHovered) > ColorProbe.alpha(surface.badgeWash),
                    "\(surface) does not answer to the pointer")
        }
    }

    @Test func theDefaultSurfaceIsTheSheet() {
        // A component used outside the sidebar must look right without anyone setting the
        // environment — the common case should need no ceremony.
        #expect(EnvironmentValues().surface == .sheet)
    }

    @Test func theOccludingBackgroundIsAlwaysOpaque() {
        // A ring or divider painted *over* content — AvatarGroupView's ring over the avatar behind
        // it — needs a colour that occludes. A wash with any transparency lets what's underneath
        // show through, which is the one thing this property exists to prevent.
        for surface in Self.every {
            #expect(ColorProbe.alpha(surface.occludingBackground) == 1,
                    "\(surface) does not occlude")
        }
    }

    @Test func theOccludingBackgroundIsTheRightColourPerSurface() {
        // Opacity alone would not have caught `.selected` and `.hover` swapped — both are opaque.
        // `AvatarGroupView`'s ring painted over a task row's avatars is what these colours are for
        // (`SidebarView.swift`'s old `ring` computation, folded into `Surface` here), so each one is
        // pinned to the exact palette entry it must render as: a selected row's over the ground the
        // row sits on, the sidebar's or the sheet's.
        #expect(Icon.hexString(Surface.sidebar.occludingBackground) == Icon.hexString(Palette.sidebar))
        #expect(Icon.hexString(Surface.hover.occludingBackground) == Icon.hexString(Palette.rowHoverSolid))
        #expect(Icon.hexString(Surface.selected.occludingBackground) == Icon.hexString(Palette.selectedSolid))
        #expect(Icon.hexString(Surface.selectedOnSheet.occludingBackground) == Icon.hexString(Palette.selectedOnSheetSolid))
        #expect(Icon.hexString(Surface.accent.occludingBackground) == Icon.hexString(Palette.accent))
        #expect(Icon.hexString(Surface.sheet.occludingBackground) == Icon.hexString(Palette.surface))
        #expect(Icon.hexString(Surface.washed.occludingBackground) == Icon.hexString(Palette.operatorRowSolid))
        #expect(Icon.hexString(Surface.washedHover.occludingBackground) == Icon.hexString(Palette.operatorRowHoveredSolid))
        // And no two grounds share one, which a copied line would.
        #expect(Set(Self.every.map { Icon.hexString($0.occludingBackground) }).count == Self.every.count)
    }

    /// The Operator's row is washed, not selected: its ink is the sidebar's.
    @Test func aWashedRowInksAsTheSidebarDoes() {
        for surface in [Surface.washed, .washedHover] {
            #expect(!surface.isOnAccent)
            #expect(Icon.hexString(surface.ink) == Icon.hexString(Surface.sidebar.ink))
        }
    }
}
