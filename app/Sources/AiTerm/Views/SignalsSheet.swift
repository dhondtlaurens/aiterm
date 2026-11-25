import SwiftUI
import AiTermUI
import AiTermCore

/// A section's signals, in their priority order, as the Archive lists its tasks: each row its source's mark, its name,
/// when it starts and when it is done, and what needs the person in the warning ink. Its menu, as a context menu and
/// behind its trailing button, edits, switches, moves and removes it; a double-click edits it. No switch per row:
/// Switch On starts every item that matches, so it is a menu's deliberate choice. The footer makes a new one.
struct SignalsSheet: View {
    let model: SignalsSheetModel
    @Environment(\.dismiss) private var dismiss
    @State private var hovered: UUID?

    var body: some View {
        let rows = model.rows
        SheetLayout(title: model.title, height: .fixed(Sheet.height), contentVerticalPadding: rows.isEmpty ? Space.margin : Space.base) {
            EmptyView()
        } content: {
            if rows.isEmpty {
                Text(model.emptyText).font(Typography.body).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVStack(spacing: Space.hairline) {
                    ForEach(rows) { row in
                        let commands = commands(for: row)
                        SignalsSheetRow(row: row, commands: commands)
                            .modifier(RowPill(selected: false, hovered: hovered == row.id, ground: .sheet))
                            .onHover { inside in
                                if inside { hovered = row.id } else if hovered == row.id { hovered = nil }
                            }
                            .onTapGesture(count: 2) { if model.canEdit { model.edit(row.id) } }
                            .modifier(RowCommandContextMenu(groups: commands))
                    }
                }
            }
        } footer: {
            HStack(spacing: Space.base) {
                Button("New Signal…") { model.new() }.disabled(!model.canEdit)
                Spacer(minLength: Space.base)
                SheetPrimaryButton(title: "Done", enabled: true) { dismiss.afterThisEvent() }
            }
            .buttonStyle(.push(.secondary))
            .sheetEscapeKey(closeList: { false }, cancel: { dismiss.afterThisEvent() })
        }
    }

    /// A row's menu, the same in its context menu, behind its button and as its spoken actions.
    private func commands(for row: SignalsSheetModel.Row) -> [[RowCommand]] {
        let id = row.id, enabled = model.canChange
        return [
            [RowCommand(title: "Edit Signal…", enabled: model.canEdit) { model.edit(id) },
             RowCommand(title: row.switchedOff ? "Switch On" : "Switch Off", enabled: enabled) { model.switchOnOff(id) }],
            [RowCommand(title: "Move Up", enabled: enabled && row.canMoveUp) { model.move(id, .up) },
             RowCommand(title: "Move Down", enabled: enabled && row.canMoveDown) { model.move(id, .down) }],
            [RowCommand(title: "Remove Signal…", role: .destructive, enabled: enabled) { model.remove(id) }],
        ]
    }
}

/// One signal in the signals sheet: its source's mark, its name, its trigger lines and its issues, a switched-off one
/// faded with the pause glyph, and its menu's button at the trailing edge. Inked from its `Surface`, which the pill
/// around it declares.
struct SignalsSheetRow: View {
    let row: SignalsSheetModel.Row
    let commands: [[RowCommand]]
    @Environment(\.surface) private var surface

    var body: some View {
        HStack(alignment: .top, spacing: Space.inset) {
            HStack(alignment: .top, spacing: Space.inset) {
                ProviderIcon(row.mark)
                VStack(alignment: .leading, spacing: Space.tight) {
                    Text(row.name).font(Typography.bodyEmphasis).foregroundStyle(surface.ink)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(minHeight: Size.avatar)
                    ForEach(Array(row.lines.enumerated()), id: \.offset) { HelpText($0.element).lineLimit(2).truncationMode(.tail) }
                    ForEach(Array(row.issues.enumerated()), id: \.offset) { HelpText($0.element, tone: .warning).lineLimit(2).truncationMode(.tail) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .opacity(row.switchedOff ? Opacity.disabled : 1)
            .accessibilityElement(children: .combine)
            .accessibilityValue(row.switchedOff ? "switched off" : "")
            .modifier(RowCommandActions(groups: commands))
            if row.switchedOff {
                Image(systemName: "pause.fill").font(Typography.chip).foregroundStyle(Palette.tertiary)
                    .frame(width: Size.slot, height: Size.avatar)
                    .help("Switched off")
                    .accessibilityHidden(true)
            }
            Menu { RowCommandMenu(groups: commands) } label: {
                Image(systemName: "ellipsis").font(Typography.label).foregroundStyle(surface.secondaryInk)
                    .frame(width: Size.slot, height: Size.avatar)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .fixedSize()
            .help("Signal actions")
            .accessibilityLabel("Actions for \(row.name)")
        }
        .padding(Space.base)
        .frame(minHeight: Size.row, alignment: .top)
        .contentShape(Rectangle())
    }
}
