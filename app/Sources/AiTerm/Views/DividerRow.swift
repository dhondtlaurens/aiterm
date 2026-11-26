import SwiftUI
import AiTermUI
import AiTermCore

/// A named rule between two projects. A label, not a container: it holds nothing, selects nothing
/// and hovers to nothing — only its context menu responds, and in the Operator's section it has none
/// (`commandsShown` false): there it only heads the projects under it.
///
/// The name takes the Projects header's exact treatment and place, because that is what it is: a
/// heading for the projects under it, leading at the headings' x, in its own case as the person typed
/// it; one rule fills the rest of the row. A divider with no name is the rule alone. The rule is the
/// house `Hairline`, which stays horizontal inside an `HStack` where SwiftUI's own `Divider` turns
/// vertical. In the Operator's section the rule ends before the trailing slot, which carries the Operator's status
/// line through it.
struct DividerRow: View {
    let entry: DividerEntry
    let enabled: Bool
    let rename: () -> Void
    let move: (MoveStep) -> Void
    let delete: () -> Void
    /// Whether it offers Rename, Move and Remove: in the projects, not in the Operator's section.
    var commandsShown = true
    /// The rows whose status line its trailing slot carries: in the Operator's section only.
    var statusLine: SidebarProjection? = nil
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
            if statusLine != nil {
                Color.clear.frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
            }
        }
        .frame(height: scale(Size.menuRow))
        .modifier(StatusLineOverlay(id: entry.id, rows: statusLine, reach: StatusLineReach.halfGap))
        .modifier(SidebarHeadingInset())
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name.isEmpty ? "Divider" : "\(name) divider")
        .modifier(RowCommandActions(groups: commands))
        .modifier(RowCommandContextMenu(groups: commands))
    }

    func commands() -> [[RowCommand]] {
        guard commandsShown else { return [] }
        return [
            [RowCommand(title: "Rename…", enabled: enabled, action: rename)],
            [RowCommand(title: "Move Up", enabled: enabled && entry.canMove(.up)) { move(.up) },
             RowCommand(title: "Move Down", enabled: enabled && entry.canMove(.down)) { move(.down) }],
            [RowCommand(title: "Remove Divider", role: .destructive, enabled: enabled, action: delete)]
        ]
    }
}
