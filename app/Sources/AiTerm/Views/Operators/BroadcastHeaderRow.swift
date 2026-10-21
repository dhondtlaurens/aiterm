import SwiftUI
import AiTermUI
import AiTermCore

/// The broadcast under the OPERATOR heading, on a task row's grid (spec §3, §13): the Operator's agent as
/// its avatar, the title over its status line (`BroadcastStatusLine`: the operator badge, then
/// `· 2 of 8 done` once there is a plan), a folded task row's height, its projects in the tooltip, and
/// its `StatusMark` trailing. ↑ ↓ peek at
/// the Operator's window, as on a task row; a click or ↩ opens the overview, and with the Operator's window
/// closed reopens it behind the sheet (`AppController.openBroadcast`). Its menu: Rename…, Pause Broadcast
/// or Resume Broadcast, End Broadcast….
struct BroadcastRowView: View {
    /// Everything the row draws, its menu included: an equatable value, so a change to the run it draws
    /// nothing of (a decision recorded, a token) does not re-run this body.
    let row: BroadcastRow
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
                    BroadcastStatusLine(line: row.line, progress: row.progress)
                }
                // Laid out before the spacer, so the status line takes the row's width before it is cut:
                // as an equal share with the spacer, a line wider than the row's second was cut short.
                .layoutPriority(1)
                Spacer(minLength: scale(Space.tight))
                StatusMark(status: row.status, size: SidebarRowLayout.trailingGlyph(scale))
                    .frame(width: SidebarRowLayout.trailingSlot(scale))
            }
        }
        .help(row.projectsHelp)
        .accessibilityLabel(Self.label(row))
        .accessibilityValue(Self.spoken(row))
        .accessibilityHint(Text("Press Return to open the broadcast’s overview."))
        // The menu's items as VoiceOver actions, as a task's and a terminal's row offer theirs.
        .accessibilityActions {
            ForEach(Self.voiceOverActions(row, canChangeWorkspace: controller.canChangeWorkspace), id: \.self) { item in
                Button(item.actionTitle) { controller.perform(item, onBroadcast: row.id) }
            }
        }
        .contextMenu {
            OperatorMenuButtons(items: OperatorMenus.broadcast(row), enabled: { _ in controller.canChangeWorkspace }) {
                controller.perform($0, onBroadcast: row.id)
            }
        }
    }

    /// What VoiceOver offers: the menu's items, none while the workspace is locked, where the menu greys
    /// them: an action cannot be greyed, only left out.
    static func voiceOverActions(_ row: BroadcastRow, canChangeWorkspace: Bool) -> [OperatorMenuItem] {
        canChangeWorkspace ? OperatorMenus.broadcast(row).filter { $0 != .separator } : []
    }

    /// A project's host as New Broadcast marks it: the mark its header's `ProviderIcon` draws.
    static func hostIcon(_ provider: Provider) -> IconSource {
        switch provider {
        case .gitlab: .gitlabTanuki
        case .github: .brand(Palette.github)
        case .git: .symbol("arrow.triangle.branch")
        case .none: .symbol("folder.fill")
        }
    }

    /// What VoiceOver calls the row.
    static func label(_ row: BroadcastRow) -> String { "Broadcast \(row.title)" }

    /// The row's lines as VoiceOver reads them: the progress, every project, and the whole status line.
    static func spoken(_ row: BroadcastRow) -> String {
        [row.progress, row.projectsHelp.isEmpty ? nil : row.projectsHelp, row.line.tooltip].compactMap { $0 }.joined(separator: ", ")
    }
}
