import SwiftUI
import AiTermUI
import AiTermCore

/// The Operator's own row, first under the OPERATOR heading and the broadcast's lead (decided 21 Oct 2026; 28 Oct
/// 2026 titled with the broadcast): a full task row (`SelectableRow`) washed at rest (`Palette.operatorRow`), which
/// alone tells it from its tasks, Claude's `VendorMark` as its avatar, the broadcast's name as its title, then its
/// own session's line, `OperatorBadge(line:)`, and the shared task mark trailing, a completed check once the
/// broadcast succeeds. No project, ticket or branch line: the board has all of that. ↑ ↓ peek at its window, as on
/// a task; a click or ↩ brings it to front with iTerm2, or reopens it in front when it is closed
/// (`RowFocus.select(.operation)`). Its context menu is the broadcast's (`BroadcastMenu`), which the heading has too.
struct OperatorRowView: View {
    let row: OperatorRow
    let controller: AppController
    @Environment(\.interfaceScale) private var scale
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    /// What VoiceOver calls the row.
    static func label(_ row: OperatorRow) -> String { "\(row.title), the Operator’s Claude Code session" }

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(row.id)
        #endif
        let selected = controller.focus.isSelected(row.id)
        SelectableRow(id: row.id, selected: selected, washed: true, activate: { controller.focus.select(.operation(row.runId)) }) {
            HStack(spacing: scale(Space.inset)) {
                AvatarGroupView(group: AvatarGroup(marks: [row.agent], overflow: 0))
                VStack(alignment: .leading, spacing: scale(Space.tight)) {
                    RowTitle(row.title)
                    OperatorBadge(line: row.line)
                }
                // Laid out before the spacer, so the line takes the row's width before it is cut.
                .layoutPriority(1)
                Spacer(minLength: scale(Space.tight))
                TaskRowMarkView(mark: TaskRowMark(status: row.status, line: row.line, removing: false),
                                size: SidebarRowLayout.trailingGlyph(scale))
                    .frame(width: SidebarRowLayout.trailingSlot(scale))
            }
        }
        .accessibilityLabel(Self.label(row))
        .accessibilityValue(row.line.tooltip)
        .accessibilityHint(Text("Press Return to bring its window to front."))
        .contextMenu { BroadcastMenu(runId: row.runId, controller: controller) }
    }
}
