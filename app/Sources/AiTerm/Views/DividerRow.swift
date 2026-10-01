import SwiftUI
import AiTermUI
import AiTermCore

/// A named rule between two projects. A label, not a container: it holds nothing, selects nothing
/// and hovers to nothing — only its context menu responds.
///
/// The name takes the `PROJECTS` header's exact treatment, because that is what it is: a heading for
/// the projects under it. The rule is the house `Hairline`, which stays horizontal inside an
/// `HStack` where SwiftUI's own `Divider` turns vertical.
struct DividerRow: View {
    let entry: DividerEntry
    let enabled: Bool
    let rename: () -> Void
    let move: (MoveStep) -> Void
    let delete: () -> Void
    @Environment(\.interfaceScale) private var scale

    private var name: String { entry.divider.name }
    /// A locked workspace moves nothing; otherwise the list says which way there is room.
    private func canMove(_ step: MoveStep) -> Bool { enabled && entry.canMove(step) }

    var body: some View {
        HStack(spacing: scale(Space.base)) {
            Hairline()
            if !name.isEmpty {
                SidebarHeading(name)
                    .lineLimit(1).truncationMode(.tail).fixedSize(horizontal: true, vertical: false)
                Hairline()
            }
        }
        .frame(height: scale(Size.menuRow))
        .padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name.isEmpty ? "Divider" : "\(name) divider")
        .accessibilityActions {
            ForEach(Self.actions(enabled: enabled, canMove: canMove), id: \.self) { action in
                Button(action.rawValue) { perform(action) }
            }
        }
        .contextMenu {
            Button("Rename…", action: rename).disabled(!enabled)
            Divider()
            // Disabled at the edges rather than absent, exactly as a project's menu does it.
            Button("Move Up") { move(.up) }.disabled(!canMove(.up))
            Button("Move Down") { move(.down) }.disabled(!canMove(.down))
            Divider()
            // No confirmation: unlike removing a project this destroys nothing but the label.
            Button("Remove Divider", role: .destructive, action: delete).disabled(!enabled)
        }
    }

    enum Action: String, CaseIterable, Hashable {
        case rename = "Rename", moveUp = "Move Up", moveDown = "Move Down", delete = "Remove Divider"
    }

    /// What VoiceOver offers: the context menu's items that are enabled now. The menu greys the rest
    /// rather than dropping them, but a VoiceOver action cannot be greyed — only left out.
    static func actions(enabled: Bool, canMove: (MoveStep) -> Bool) -> [Action] {
        Action.allCases.filter { action in
            switch action {
            case .rename, .delete: return enabled
            case .moveUp: return canMove(.up)
            case .moveDown: return canMove(.down)
            }
        }
    }

    private func perform(_ action: Action) {
        switch action {
        case .rename: rename()
        case .moveUp: move(.up)
        case .moveDown: move(.down)
        case .delete: delete()
        }
    }
}
