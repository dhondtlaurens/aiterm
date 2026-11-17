import SwiftUI
import AiTermUI
import AiTermCore

/// A named rule between two projects. A label, not a container: it holds nothing, selects nothing
/// and hovers to nothing — only its context menu responds.
///
/// The name takes the Projects header's exact treatment and place, because that is what it is: a
/// heading for the projects under it, leading at the headings' x, in its own case as the person typed
/// it; one rule fills the rest of the row. A divider with no name is the rule alone. The rule is the
/// house `Hairline`, which stays horizontal inside an `HStack` where SwiftUI's own `Divider` turns
/// vertical.
struct DividerRow: View {
    let entry: DividerEntry
    let enabled: Bool
    let rename: () -> Void
    let move: (MoveStep) -> Void
    let delete: () -> Void
    @Environment(\.interfaceScale) private var scale

    private var name: String { entry.divider.name }
    var body: some View {
        let commands = commands()
        HStack(spacing: scale(Space.base)) {
            if !name.isEmpty {
                SidebarHeading(name)
                    .lineLimit(1).truncationMode(.tail).fixedSize(horizontal: true, vertical: false)
            }
            Hairline()
        }
        .frame(height: scale(Size.menuRow))
        .modifier(SidebarHeadingInset())
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name.isEmpty ? "Divider" : "\(name) divider")
        .modifier(RowCommandActions(groups: commands))
        .modifier(RowCommandContextMenu(groups: commands))
    }

    func commands() -> [[RowCommand]] {
        [
            [RowCommand(title: "Rename…", enabled: enabled, action: rename)],
            [RowCommand(title: "Move Up", enabled: enabled && entry.canMove(.up)) { move(.up) },
             RowCommand(title: "Move Down", enabled: enabled && entry.canMove(.down)) { move(.down) }],
            [RowCommand(title: "Remove Divider", role: .destructive, enabled: enabled, action: delete)]
        ]
    }
}
