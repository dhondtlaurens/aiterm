import SwiftUI
import AiTermUI
import AiTermCore

/// Archived tasks and reviews, newest first under their dates' groups, searched from the navigation band: a
/// `ListSheet`. ↑ ↓ move the highlight, ⌘↩ or a double-click restores it, ⌘⌫ asks Remove's question, and ⎋ clears a
/// search then closes. The search field keeps the keyboard throughout. Each row's gear has Restore and Remove….
struct ArchiveSheet: View {
    let model: ArchiveSheetModel
    @Environment(\.dismiss) private var dismiss
    /// The snapshots' fixed calendar and locale, so a row's group reads the same on every machine; the app's own
    /// otherwise.
    @Environment(\.footerClock) private var clock

    var body: some View {
        let archive = model.projection
        let calendar = clock?.calendar ?? .current
        ListSheet(title: "Archive", placeholder: "Search title, ticket, !MR, branch, project", query: Bindable(model).query,
                  groups: model.groups(calendar: calendar, locale: calendar.locale ?? .current), hasItems: archive.total > 0,
                  noMatch: { "No archived task matches “\($0)”." }, highlighted: archive.highlighted?.id,
                  highlight: model.highlight, activate: { _ in perform() }, command: command, commands: commands) { entry in
            ArchiveRow(entry: entry, commands: commands(entry))
        } empty: {
            VStack(alignment: .leading, spacing: Space.base) {
                Text("Nothing on the archive yet.").font(Typography.body).foregroundStyle(Palette.text)
                HelpText("Archive a task from its menu to put its worktree away and keep its conversations.")
            }
        } footer: {
            // Nothing archived: no count and no Restore button.
            SheetFooter(secondary: "Close", primary: archive.primaryTitle, closeList: model.clearQuery,
                        cancel: { dismiss.afterThisEvent() }, submit: perform) {
                if archive.total > 0 { HelpText(archive.status) }
            }
        }
    }

    /// A row's menu, the same behind its gear, as its context menu and as its spoken actions.
    private func commands(_ entry: ArchiveSearch.Entry) -> [[RowCommand]] {
        let id = entry.id
        return [[RowCommand(title: "Restore") { model.highlight(id); perform() }],
                [RowCommand(title: "Remove…", role: .destructive) { model.remove(id) }]]
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

/// One archived task or review, as its row reads in the sidebar: the task row's grid with its agent's mark in the
/// avatar column, the title, then the ticket and merge request badges, the branch and the project; the gear where the
/// status mark sits. An archived task keeps no diff and no worktree, so its request badge carries none. Inked from its
/// `Surface`, which the pill around it declares.
struct ArchiveRow: View {
    let entry: ArchiveSearch.Entry
    let commands: [[RowCommand]]
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
        ListSheetRow(title: task.title, commands: commands) {
            AvatarGroupView(group: AvatarGroup(marks: [task.agent.session], overflow: 0))
        } detail: {
            // The sidebar's order: ticket, merge request, then the branch, which is what truncates; the project last,
            // kept whole.
            HStack(spacing: Space.gap) {
                badges
                Text(task.branch).font(Typography.mono).foregroundStyle(surface.secondaryInk)
                    .lineLimit(1).truncationMode(.middle)
                HelpText(entry.projectName, fixedVerticalSize: false).lineLimit(1).fixedSize()
            }
        }
    }
}
