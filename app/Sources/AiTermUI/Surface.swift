import SwiftUI

/// The ground a component is drawn on. A component reads this from the environment instead of
/// taking a `selected` flag, so a badge inside a selected sidebar row strengthens its wash by itself.
///
/// This replaces the `onSelection: Bool` that `EditorBadge`, `JiraChip`, `BranchLabelView` and
/// `StatusMark` each took and each re-derived the same colours from.
public enum Surface: Equatable, Sendable {
    /// The sidebar's own background, and any row at rest.
    case sidebar
    /// A hovered row: the sidebar plus a white wash.
    case hover
    /// A hovered row on a sheet: the sheet plus `Palette.rowHover`. Its inks and washes are `hover`'s; only the
    /// ground beneath, and so `occludingBackground`, differs.
    case hoverOnSheet
    /// A row washed at rest, the Operator's: the sidebar plus `Palette.operatorRow`.
    case washed
    /// That row hovered: the sidebar plus `Palette.badgeHovered`, in the wash's place.
    case washedHover
    /// A selected sidebar row: `Palette.selected` over the sidebar. Neutral, not the accent: the
    /// title lifts to white, the secondary ink stays `muted`, and every mark keeps its own colour —
    /// amber, green, the spinner, the done ring, a brand.
    case selected
    /// A selected row on a sheet — the Archive's: `Palette.selected` over the sheet. Inked as
    /// `selected`; only the ground beneath, and so `occludingBackground`, differs.
    case selectedOnSheet
    /// The accent: a primary button's label.
    /// Everything on it turns white.
    case accent
    /// A sheet or any other surface away from the sidebar. The default.
    case sheet

    public var isOnAccent: Bool { self == .accent }
    /// A selected row, on the sidebar or on a sheet.
    public var isSelected: Bool { self == .selected || self == .selectedOnSheet }

    public var ink: Color { isOnAccent || isSelected ? Palette.onAccent : Palette.text }
    public var secondaryInk: Color { isOnAccent ? Palette.onAccentSecondary : Palette.muted }
    public var badgeWash: Color { isOnAccent || isSelected ? Palette.badgeSelected : Palette.badge }
    public var badgeWashHovered: Color { isOnAccent || isSelected ? Palette.badgeSelectedHovered : Palette.badgeHovered }

    /// The surface's own colour, opaque. A ring or divider painted *over* content needs this rather
    /// than a wash: `AvatarGroupView`'s ring has to occlude the avatar behind it, and a translucent
    /// colour lets the stacked marks show through.
    public var occludingBackground: Color {
        switch self {
        case .sidebar: Palette.sidebar
        case .hover: Palette.rowHoverSolid
        case .hoverOnSheet: Palette.rowHoverOnSheetSolid
        case .washed: Palette.operatorRowSolid
        case .washedHover: Palette.operatorRowHoveredSolid
        case .selected: Palette.selectedSolid
        case .selectedOnSheet: Palette.selectedOnSheetSolid
        case .accent: Palette.accent
        case .sheet: Palette.surface
        }
    }
}

private struct SurfaceKey: EnvironmentKey {
    static let defaultValue: Surface = .sheet
}

public extension EnvironmentValues {
    var surface: Surface {
        get { self[SurfaceKey.self] }
        set { self[SurfaceKey.self] = newValue }
    }
}

public extension View {
    /// Declares the ground everything inside is drawn on.
    func surface(_ surface: Surface) -> some View {
        environment(\.surface, surface)
    }
}
