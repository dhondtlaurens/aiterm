import Testing
import SwiftUI
@testable import AiTermUI

@MainActor
struct SurfaceTests {
    @Test func accentSurfaceInksWhite() {
        // On a selected row the ground is the accent, so every mark and label turns white — a
        // brand colour or a grey label on the accent reads as a bug. This is the rule the
        // `onSelection` boolean encoded at four separate call sites.
        #expect(Icon.hexString(Surface.accent.ink) == "#FFFFFF")
        #expect(Surface.accent.isOnAccent)
    }

    @Test func restingSurfacesUseThePaletteInk() {
        for surface in [Surface.sidebar, .hover, .sheet] {
            #expect(ColorProbe.rgba(surface.ink) == ColorProbe.rgba(Palette.text))
            #expect(!surface.isOnAccent)
        }
    }

    @Test func theBadgeWashStrengthensOnTheAccent() {
        // The wash has to read against whatever is behind it: ≈6.8 % white on the sidebar (8 % of
        // `.primary`, itself ≈85 % white), 20 % on the accent. Getting this backwards makes a badge
        // vanish on a selected row.
        let resting = ColorProbe.alpha(Surface.sidebar.badgeWash)
        let selected = ColorProbe.alpha(Surface.accent.badgeWash)
        #expect(selected > resting, "the wash must strengthen on the accent, not weaken")
    }

    @Test func hoverStrengthensEveryWash() {
        for surface in [Surface.sidebar, .hover, .accent, .sheet] {
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
        for surface in [Surface.sidebar, .hover, .washed, .washedHover, .accent, .sheet] {
            #expect(ColorProbe.alpha(surface.occludingBackground) == 1,
                    "\(surface) does not occlude")
        }
    }

    @Test func theOccludingBackgroundIsTheRightColourPerSurface() {
        // Opacity alone would not have caught `.accent` and `.hover` swapped — both are opaque.
        // `AvatarGroupView`'s ring painted over a task row's avatars is what these four colours
        // are for (`SidebarView.swift`'s old `ring` computation, folded into `Surface` here), so
        // each one is pinned to the exact palette entry it must render as.
        #expect(Icon.hexString(Surface.sidebar.occludingBackground) == Icon.hexString(Palette.sidebar))
        #expect(Icon.hexString(Surface.hover.occludingBackground) == Icon.hexString(Palette.rowHoverSolid))
        #expect(Icon.hexString(Surface.accent.occludingBackground) == Icon.hexString(Palette.selection))
        #expect(Icon.hexString(Surface.sheet.occludingBackground) == Icon.hexString(Palette.surface))
        #expect(Icon.hexString(Surface.washed.occludingBackground) == Icon.hexString(Palette.operatorRowSolid))
        #expect(Icon.hexString(Surface.washedHover.occludingBackground) == Icon.hexString(Palette.operatorRowHoveredSolid))
    }

    /// The Operator's row is washed, not selected: its ink is the sidebar's.
    @Test func aWashedRowInksAsTheSidebarDoes() {
        for surface in [Surface.washed, .washedHover] {
            #expect(!surface.isOnAccent)
            #expect(Icon.hexString(surface.ink) == Icon.hexString(Surface.sidebar.ink))
        }
    }
}
