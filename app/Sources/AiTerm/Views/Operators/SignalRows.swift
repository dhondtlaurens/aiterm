import SwiftUI
import AiTermUI
import AiTermCore

/// The active workload’s row uses the same avatar, title, caption and trailing-mark grid as a task.
struct SignalOperatorRow: View {
    let value: SignalOperatorRowValue
    let controller: AppController
    @Environment(\.interfaceScale) private var scale
    private var row: UUID { OperatorSession.rowID }
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif
    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(row)
        #endif
        let line = value.line
        SelectableRow(id: row, selected: controller.focus.isSelected(row), washed: true,
                      activate: { controller.choose(.operatorChat) }) {
            SidebarRowContent(avatars: AvatarGroup(marks: [.claude], overflow: 0)) {
                VStack(alignment: .leading, spacing: scale(Space.tight)) {
                    RowTitle("Operator")
                    OperatorActivityCaption(line: line, completed: value.completedActivity, event: value.event)
                }.layoutPriority(1)
            } mark: {
                TaskRowMarkView(mark: value.mark, size: SidebarRowLayout.trailingGlyph(scale))
                    .frame(width: SidebarRowLayout.trailingSlot(scale))
            }
        }
        .contextMenu {
            Button(value.paused ? "Resume" : "Pause") { Task { await controller.signalController.setPaused(!value.paused) } }
                .disabled(!controller.canChangeWorkspace)
        }
        .help(line.tooltip)
        .accessibilityLabel("Operator, Claude Code session")
        .accessibilityValue(line.tooltip)
    }
}
