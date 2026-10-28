import SwiftUI
import AiTermUI
import AiTermCore

/// Every archived task and review and every ended broadcast, newest first, searched from the navigation
/// band: ↑ ↓ move the highlight, ⌘↩ or a double-click restores it — or, on a broadcast, opens its sheet in
/// the Shelf's place — ⌘⌫ asks Remove's question about it, ⎋ clears a search and then closes. The search
/// field keeps the keyboard throughout, so its commands are the sheet's: ⌘⌫ — a field's
/// delete-to-line-start — removes the highlighted row instead, ⎋ having cleared the line.
struct ArchiveSheet: View {
    let model: ArchiveSheetModel
    @Environment(\.dismiss) private var dismiss
    /// The snapshots' fixed calendar and locale, so a row's date reads the same on every machine; the
    /// app's own otherwise.
    @Environment(\.footerClock) private var clock
    // `@State` is a macro shipping only with Xcode; this is the storage it would generate.
    private var _focused = State(initialValue: true)

    private var focused: Bool {
        get { _focused.wrappedValue }
        nonmutating set { _focused.wrappedValue = newValue }
    }

    var body: some View {
        let archive = model.projection
        let rows = archive.rows, highlighted = archive.highlighted?.id, total = archive.total, primary = archive.primaryTitle
        let now = model.now(), calendar = clock?.calendar ?? .current
        SheetLayout(title: "Shelf", height: Sheet.height, contentVerticalPadding: rows.isEmpty ? Space.margin : Space.base) {
            HStack(spacing: Space.base) {
                Image(systemName: "magnifyingglass").font(Typography.caption).foregroundStyle(Palette.muted)
                SearchField(placeholder: "Search title, ticket, !MR, branch, project",
                            text: Bindable(model).query, focused: _focused.projectedValue, onCommand: command)
            }
            .fieldChrome(focused: focused)
        } content: {
            if total == 0 {
                VStack(alignment: .leading, spacing: Space.base) {
                    Text("Nothing on the shelf yet.").font(Typography.body).foregroundStyle(Palette.text)
                    HelpText("Shelve a task from its menu to put its worktree away and keep its conversations.")
                }
            } else if rows.isEmpty {
                Text("No shelved task matches “\(model.query.trimmingCharacters(in: .whitespaces))”.")
                    .font(Typography.body).foregroundStyle(Palette.text)
            } else {
                ScrollViewReader { scroller in
                    VStack(spacing: Space.hairline) {
                        ForEach(rows) { row in
                            let date = ArchiveDate.label(row.shelvedAt, now: now, calendar: calendar, locale: calendar.locale ?? .current)
                            Group {
                                switch row {
                                case .task(let entry): ArchiveRow(entry: entry, date: date)
                                case .broadcast(let broadcast): ShelvedBroadcastRow(broadcast: broadcast, date: date)
                                }
                            }
                            .modifier(RowPill(selected: row.id == highlighted, ground: .sheet))
                            .id(row.id)
                            .onTapGesture(count: 2) { model.highlight(row.id); perform() }
                            .onTapGesture { model.highlight(row.id) }
                            .accessibilityAddTraits(row.id == highlighted ? .isSelected : [])
                            .accessibilityAction(named: ArchiveSheetModel.primaryTitle(of: row)) { model.highlight(row.id); perform() }
                        }
                    }
                    .onChange(of: highlighted) { _, id in if let id { scroller.scrollTo(id) } }
                }
            }
        } footer: {
            // Nothing archived: no count, and no Restore — absent, not disabled. Open on an ended broadcast.
            SheetFooter(secondary: "Close", primary: primary, closeList: model.clearQuery,
                        cancel: { dismiss.afterThisEvent() }, submit: perform) {
                if total > 0 { HelpText(archive.status) }
            }
        }
    }

    /// Restore closes the sheet; Open puts the broadcast's sheet in its slot, which closes it already — a
    /// dismiss after would close the broadcast's.
    private func perform() {
        let opens = if case .broadcast? = model.projection.highlighted { true } else { false }
        guard model.performHighlighted(), !opens else { return }
        dismiss.afterThisEvent()
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

/// One archived task or review, as its row read in the sidebar: the agent's mark, the title, then the
/// ticket and merge request badges, the branch and the project, with when it was archived on the
/// title's line, where the status mark sits. Inked from its `Surface`, which the pill around it declares.
struct ArchiveRow: View {
    let entry: ArchiveSearch.Entry
    let date: String
    @Environment(\.surface) private var surface

    var badges: TaskBadges {
        let task = entry.archived.task
        let host = CodeHost(webURL: task.mr?.url ?? "")
        return TaskBadges(ticket: task.jira?.key, ticketSummary: task.jira?.summary,
                          mr: task.mr.map { host.reference($0.iid) }, mrHost: host, mrTitle: task.mr?.title)
    }

    var body: some View {
        let task = entry.archived.task
        HStack(spacing: Space.inset) {
            VendorMark(agent: task.agent.session, size: Size.avatar)
            VStack(alignment: .leading, spacing: Space.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Space.tight) {
                    RowTitle(task.title)
                    Spacer(minLength: Space.tight)
                    Text(date).font(Typography.help).foregroundStyle(surface.secondaryInk).lineLimit(1).fixedSize()
                }
                // The sidebar's order: ticket, merge request, then the branch, which is what truncates;
                // the project last, kept whole.
                HStack(spacing: Space.gap) {
                    badges
                    Text(task.branch).font(Typography.mono).foregroundStyle(surface.secondaryInk)
                        .lineLimit(1).truncationMode(.middle)
                    Text(entry.projectName).font(Typography.help).foregroundStyle(surface.secondaryInk).lineLimit(1).fixedSize()
                }
                .frame(height: Size.chip)
            }
        }
        .padding(Space.base)
        .frame(minHeight: Size.row)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// An ended broadcast on the Shelf: the broadcast header's mark, its name, and the day it ended on the
/// name's line, where a shelved task's date sits. Inked from its `Surface`, which the pill around it declares.
struct ShelvedBroadcastRow: View {
    let broadcast: ShelvedBroadcast
    let date: String
    @Environment(\.surface) private var surface

    var body: some View {
        HStack(spacing: Space.inset) {
            ProviderIcon(.symbol(OperatorHeading.glyph))
            HStack(alignment: .firstTextBaseline, spacing: Space.tight) {
                RowTitle(broadcast.name)
                Spacer(minLength: Space.tight)
                Text(date).font(Typography.help).foregroundStyle(surface.secondaryInk).lineLimit(1).fixedSize()
            }
        }
        .padding(Space.base)
        .frame(minHeight: Size.row)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .help(broadcast.asked)
    }
}
