import SwiftUI
import AiTermUI
import AiTermCore

/// A section's signals, in their priority order: a `ListSheet`, as the Archive is. Each row its source's mark, its name
/// and its description (or its query), with what needs saying as a glyph in the state column; its gear, its context
/// menu and its spoken actions edit, switch, move and remove it; a double-click edits it. No switch per row: Switch On
/// starts every item that matches, so it is a menu's deliberate choice. The footer makes a new one; Done closes.
struct SignalsSheet: View {
    let model: SignalsSheetModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rows = model.visibleRows
        ListSheet(title: model.title, placeholder: "Search name, description, query", query: Bindable(model).query,
                  groups: rows.isEmpty ? [] : [ListGroup(heading: nil, items: rows)], hasItems: !model.rows.isEmpty,
                  noMatch: { "No signal matches “\($0)”." }, highlighted: model.highlighted?.id,
                  highlight: model.highlight, activate: { if model.canEdit { model.edit($0) } }, command: command,
                  commands: commands) { row in
            SignalsSheetRow(row: row, commands: commands(for: row))
        } empty: {
            Text(model.emptyText).font(Typography.body).foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            HStack(spacing: Space.base) {
                Button("New Signal…") { model.new() }.disabled(!model.canEdit)
                Spacer(minLength: Space.base)
                SheetPrimaryButton(title: "Done", enabled: true) { dismiss.afterThisEvent() }
            }
            .buttonStyle(.push(.secondary))
            .sheetEscapeKey(closeList: model.clearQuery, cancel: { dismiss.afterThisEvent() })
        }
    }

    /// A row's menu, the same behind its gear, in its context menu and as its spoken actions.
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

    /// The search field's commands, before the field sees them.
    private func command(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): model.move(by: 1); return true
        case #selector(NSResponder.moveUp(_:)): model.move(by: -1); return true
        case #selector(NSResponder.cancelOperation(_:)): return model.clearQuery()
        case #selector(NSResponder.deleteToBeginningOfLine(_:)): return model.removeHighlighted()
        default: return false
        }
    }
}

/// One signal in a signals sheet: its source's mark, its name, its description or its query in the mono face, and its
/// state in the state column; a switched-off one faded with the pause glyph. Inked from its `Surface`, which the pill
/// around it declares.
struct SignalsSheetRow: View {
    let row: SignalsSheetModel.Row
    let commands: [[RowCommand]]
    @Environment(\.surface) private var surface

    var body: some View {
        ListSheetRow(title: row.name, dimmed: row.switchedOff, stateColumn: true, state: Self.state(row.state), commands: commands) {
            ProviderIcon(row.mark)
        } detail: {
            Text(row.detail).font(row.detailIsQuery ? Typography.mono : Typography.help).foregroundStyle(surface.secondaryInk)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    static func state(_ state: SignalsSheetModel.State?) -> ListRowState? {
        switch state {
        case .issue(let words, let detail): .issue(words, detail: detail.joined(separator: "\n"))
        case .switchedOff: .switchedOff
        case .schedule(let words): .schedule(words)
        case nil: nil
        }
    }
}
