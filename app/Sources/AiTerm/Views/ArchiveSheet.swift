import SwiftUI
import AiTermUI
import AiTermCore

/// Every archived task and review, newest first, searched from the navigation band: ↑ ↓ move the
/// highlight, ⌘↩ or a double-click restores it, ⌘⌫ asks Remove's question about it, ⎋ clears a search
/// and then closes. The search field keeps the keyboard throughout, so its commands are the sheet's:
/// ⌘⌫ — a field's delete-to-line-start — removes the highlighted row instead, ⎋ having cleared the line.
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
        // Each of the model's lists re-ranks the archive, so each is read once.
        let rows = model.rows, highlighted = model.highlighted?.archived.id, total = model.total
        let now = model.now(), calendar = clock?.calendar ?? .current
        SheetLayout(title: "Archive", height: Sheet.height, contentVerticalPadding: rows.isEmpty ? Space.margin : Space.base) {
            HStack(spacing: Space.base) {
                Image(systemName: "magnifyingglass").font(Typography.caption).foregroundStyle(Palette.muted)
                SearchField(placeholder: "Search title, ticket, !MR, branch, project",
                            text: Bindable(model).query, focused: _focused.projectedValue, onCommand: command)
            }
            .fieldChrome(focused: focused)
        } content: {
            if total == 0 {
                VStack(alignment: .leading, spacing: Space.base) {
                    Text("Nothing archived yet.").font(Typography.body).foregroundStyle(Palette.text)
                    HelpText("Archive a task from its menu to put its worktree away and keep its conversations.")
                }
            } else if rows.isEmpty {
                Text("No archived task matches “\(model.query.trimmingCharacters(in: .whitespaces))”.")
                    .font(Typography.body).foregroundStyle(Palette.text)
            } else {
                ScrollViewReader { scroller in
                    VStack(spacing: Space.hairline) {
                        ForEach(rows, id: \.archived.id) { entry in
                            ArchiveRow(entry: entry, date: ArchiveDate.label(entry.archived.archivedAt, now: now, calendar: calendar,
                                                                             locale: calendar.locale ?? .current))
                                .modifier(RowPill(selected: entry.archived.id == highlighted, ground: .sheet))
                                .id(entry.archived.id)
                                .onTapGesture(count: 2) { model.highlight(entry.archived.id); restore() }
                                .onTapGesture { model.highlight(entry.archived.id) }
                                .accessibilityAddTraits(entry.archived.id == highlighted ? .isSelected : [])
                                .accessibilityAction(named: "Restore") { model.highlight(entry.archived.id); restore() }
                        }
                    }
                    .onChange(of: highlighted) { _, id in if let id { scroller.scrollTo(id) } }
                }
            }
        } footer: {
            // Nothing archived: no count, and no Restore — absent, not disabled.
            SheetFooter(secondary: "Close", primary: highlighted == nil ? nil : "Restore", closeList: model.clearQuery,
                        cancel: { dismiss.afterThisEvent() }, submit: restore) {
                if total > 0 { HelpText(model.status) }
            }
        }
    }

    private func restore() {
        guard model.restoreHighlighted() else { return }
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
                    if let jira = task.jira { Badge(jira.key, icon: .brand(Palette.jira), help: jira.summary, style: .quiet) }
                    if let mr = task.mr {
                        // The project's host, as the badge's mark and the number's `!` or `#` say it.
                        let host: CodeHost = entry.provider == .github ? .gitHub : .gitLab
                        Badge(host.reference(mr.iid), icon: .brand(host.brand), help: mr.title, style: .quiet)
                    }
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
