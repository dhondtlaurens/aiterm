import SwiftUI
import AiTermUI
import AiTermCore

/// Archived tasks and reviews, newest first, searched from the navigation band. ↑ ↓ move the
/// highlight, ⌘↩ or a double-click restores it, ⌘⌫ asks Remove's question, and ⎋ clears a search
/// then closes. The search field keeps the keyboard throughout.
struct ArchiveSheet: View {
    let model: ArchiveSheetModel
    @Environment(\.dismiss) private var dismiss
    /// The snapshots' fixed calendar and locale, so a row's date reads the same on every machine; the
    /// app's own otherwise.
    @Environment(\.footerClock) private var clock
    @State private var focused: Bool = true

    var body: some View {
        let archive = model.projection
        let rows = archive.rows, highlighted = archive.highlighted?.id, total = archive.total, primary = archive.primaryTitle
        let now = model.now(), calendar = clock?.calendar ?? .current
        SheetLayout(title: "Archive", height: .fixed(Sheet.height), contentVerticalPadding: rows.isEmpty ? Space.margin : Space.base) {
            HStack(spacing: Space.base) {
                Image(systemName: "magnifyingglass").font(Typography.caption).foregroundStyle(Palette.muted)
                SearchField(placeholder: "Search title, ticket, !MR, branch, project",
                            text: Bindable(model).query, focused: $focused, onCommand: command)
            }
            .fieldChrome(focused: focused)
            // A field, not a line of the title: `Space.base` further from it than a subtitle.
            .padding(.top, Space.base)
        } content: {
            if total == 0 {
                VStack(alignment: .leading, spacing: Space.base) {
                    Text("Nothing on the archive yet.").font(Typography.body).foregroundStyle(Palette.text)
                    HelpText("Archive a task from its menu to put its worktree away and keep its conversations.")
                }
            } else if rows.isEmpty {
                Text("No archived task matches “\(model.query.trimmingCharacters(in: .whitespaces))”.")
                    .font(Typography.body).foregroundStyle(Palette.text)
            } else {
                ScrollViewReader { scroller in
                    LazyVStack(spacing: Space.hairline) {
                        ForEach(rows) { row in
                            let date = ArchiveDate.label(row.archived.archivedAt, now: now, calendar: calendar, locale: calendar.locale ?? .current)
                            ArchiveRow(entry: row, date: date)
                            .modifier(RowPill(selected: row.id == highlighted, ground: .sheet))
                            .id(row.id)
                            .onTapGesture(count: 2) { model.highlight(row.id); perform() }
                            .onTapGesture { model.highlight(row.id) }
                            .accessibilityAddTraits(row.id == highlighted ? .isSelected : [])
                            .accessibilityAction(named: "Restore") { model.highlight(row.id); perform() }
                        }
                    }
                    .onChange(of: highlighted) { _, id in if let id { scroller.scrollTo(id) } }
                }
            }
        } footer: {
            // Nothing archived: no count and no Restore button.
            SheetFooter(secondary: "Close", primary: primary, closeList: model.clearQuery,
                        cancel: { dismiss.afterThisEvent() }, submit: perform) {
                if total > 0 { HelpText(archive.status) }
            }
        }
    }

    private func perform() {
        guard model.performHighlighted() else { return }
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
                          mr: task.mr.map { host.reference($0.iid) }, mrHost: host, mrTitle: task.mr?.title,
                          ticketIsGitLabIssue: task.jira?.isGitLabIssue ?? false)
    }

    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(entry.archived.id)
        #endif
        let task = entry.archived.task
        HStack(spacing: Space.inset) {
            VendorMark(agent: task.agent.session, size: Size.avatar)
            VStack(alignment: .leading, spacing: Space.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Space.tight) {
                    RowTitle(task.title)
                    Spacer(minLength: Space.tight)
                    HelpText(date, fixedVerticalSize: false).lineLimit(1).fixedSize()
                }
                // The sidebar's order: ticket, merge request, then the branch, which is what truncates;
                // the project last, kept whole.
                HStack(spacing: Space.gap) {
                    badges
                    Text(task.branch).font(Typography.mono).foregroundStyle(surface.secondaryInk)
                        .lineLimit(1).truncationMode(.middle)
                    HelpText(entry.projectName, fixedVerticalSize: false).lineLimit(1).fixedSize()
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
