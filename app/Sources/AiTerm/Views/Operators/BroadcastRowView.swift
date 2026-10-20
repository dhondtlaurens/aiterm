import SwiftUI
import AiTermUI
import AiTermCore

/// The broadcast under the OPERATOR heading, on a task row's grid (spec §3, §13): the Operator's agent as
/// its avatar, the title, then `2 of 8 done` (once there is a plan), the first project after its host's
/// mark and `+n`, then its status line as the operator badge, and its `StatusMark` trailing. ↑ ↓ peek at
/// the Operator's window, as on a task row; a click or ↩ opens the overview, and with the Operator's window
/// closed reopens it behind the sheet (`AppController.openBroadcast`). Its menu: Rename…, Pause Broadcast
/// or Resume Broadcast, End Broadcast….
struct BroadcastRowView: View {
    let row: BroadcastRow
    let run: OperatorRun?
    let controller: AppController
    @Environment(\.interfaceScale) private var scale
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(row.id)
        #endif
        let selected = controller.focus.isSelected(row.id)
        SelectableRow(selected: selected, activate: { _ = controller.openBroadcast(row.id) }) {
            HStack(spacing: scale(Space.inset)) {
                AvatarGroupView(group: AvatarGroup(marks: [row.agent], overflow: 0))
                VStack(alignment: .leading, spacing: scale(Space.tight)) {
                    RowTitle(row.title)
                    // Quiet badges carry no box, so `Space.gap` keeps them apart, as on a task row; the
                    // project's name is what truncates.
                    HStack(spacing: scale(Space.gap)) {
                        if let progress = row.progress {
                            Badge(progress, style: .quiet).fixedSize().layoutPriority(2)
                        }
                        if let project = row.firstProject {
                            Badge(project.name, icon: Self.hostIcon(project.provider), help: row.projectsHelp, style: .quiet)
                        }
                        if row.moreProjects > 0 {
                            Badge("+\(row.moreProjects)", help: row.projectsHelp).fixedSize().layoutPriority(1)
                        }
                    }
                    .frame(height: scale(Size.chip))
                    OperatorBadge(line: row.line)
                }
                Spacer(minLength: scale(Space.tight))
                StatusMark(status: row.status, size: SidebarRowLayout.trailingGlyph(scale))
                    .frame(width: SidebarRowLayout.trailingSlot(scale))
            }
        }
        .accessibilityLabel(Self.label(row))
        .accessibilityValue(Self.spoken(row))
        .accessibilityHint(Text("Press Return to open the broadcast’s overview."))
        .contextMenu {
            if let run {
                OperatorMenuButtons(items: OperatorMenus.broadcast(run), enabled: { _ in controller.canChangeWorkspace }) {
                    controller.perform($0, on: run)
                }
            }
        }
    }

    /// What VoiceOver calls the row.
    static func label(_ row: BroadcastRow) -> String { "Broadcast \(row.title)" }

    /// The row's lines as VoiceOver reads them: the progress, every project, and the whole status line.
    static func spoken(_ row: BroadcastRow) -> String {
        [row.progress, row.projectsHelp.isEmpty ? nil : row.projectsHelp, row.line.tooltip].compactMap { $0 }.joined(separator: ", ")
    }

    /// A project's host as the row's second line marks it: the mark its header's `ProviderIcon` draws.
    static func hostIcon(_ provider: Provider) -> IconSource {
        switch provider {
        case .gitlab: .gitlabTanuki
        case .github: .brand(Palette.github)
        case .git: .symbol("arrow.triangle.branch")
        case .none: .symbol("folder.fill")
        }
    }
}
