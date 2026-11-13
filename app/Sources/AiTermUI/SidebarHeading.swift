import SwiftUI

/// A heading in the sidebar's own voice — Projects, System, Usage, a divider's name, a board column's:
/// the section face (`Typography.section`, 11 semibold) in the third ink (`Palette.tertiary`), its
/// words as given. Sentence case, never uppercased and never tracked (the layered foundation, 13 Nov
/// 2026): the caller's string is what is drawn, so a divider keeps its name as the person typed it.
///
/// Drawn in the sidebar, so it is drawn at the sidebar's scale: its one token is
/// `Typography.section`, which scales by itself. It has no states; it is a label, never a control.
public struct SidebarHeading: View {
    private let title: String

    /// The heading's face. Public for the one heading that draws its own words, the Operator's while
    /// it decodes, which must set them alike.
    public static let style = Typography.section
    /// The heading's ink, public for the same reason.
    public static let ink = Palette.tertiary

    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title).font(Self.style).foregroundStyle(Self.ink)
    }
}
