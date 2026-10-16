import SwiftUI
import AiTermUI
import AiTermCore

/// One operation under its operator, on a task row's grid (spec §10.3): the agents at work in it, its
/// name, its caption chips, and its state — the operation's, so an idle operator over a stuck operation
/// cannot look calm. A click or ↩ brings its chat, the operator's window, forward; ↑ ↓ peek at it; its
/// caption chips, Overview… in its menu, or ⌘I open its overview.
struct OperationRowView: View {
    let row: OperationRow
    let run: OperatorRun?
    let controller: AppController
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        let selected = controller.focus.isSelected(row.id)
        SelectableRow(selected: selected, activate: { controller.focus.select(.operation(row.id)) }) {
            HStack(spacing: scale(Space.inset)) {
                AvatarGroupView(group: row.avatars)
                VStack(alignment: .leading, spacing: scale(Space.tight)) {
                    RowTitle(row.name)
                    OperationCaptionLine(row: row) { controller.presentOverview(run: row.id) }
                }
                Spacer(minLength: scale(Space.tight))
                StatusMark(status: row.status, size: SidebarRowLayout.trailingGlyph(scale))
                    .frame(width: SidebarRowLayout.trailingSlot(scale))
            }
        }
        .accessibilityLabel("Operation \(row.name)")
        .accessibilityValue(OperationCaptionLine.spoken(row))
        .accessibilityHint(Text("Press Return to go to its operator’s window, Command I for its overview."))
        .accessibilityActions {
            Button("Overview") { controller.presentOverview(run: row.id) }
        }
        .contextMenu {
            if let run {
                OperatorMenuButtons(items: OperatorMenus.operation(run.state),
                                    enabled: { $0 == .overview || controller.canChangeWorkspace }) { controller.perform($0, on: run) }
            }
        }
    }
}

/// An operation row's second line. Its progress as a quiet `Badge` and what waits on you as an
/// attention `StatusCountChips` — both buttons opening the overview, as a task row's merge-request badge
/// is one; or, when the operation's state says more than its progress — a plan waiting, paused, its
/// operator offline, done — that state as a `RowCaption`, amber when it waits on you, which opens the
/// overview too.
struct OperationCaptionLine: View {
    let row: OperationRow
    let openOverview: () -> Void
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack(spacing: scale(Space.gap)) {
            if row.showsProgress {
                Badge(row.caption, help: "Show the overview", style: .quiet, action: openOverview)
                if row.attention > 0 {
                    Button(action: openOverview) {
                        StatusCountChips(counts: [StatusCount(status: .needsInput, count: row.attention)])
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button(action: openOverview) { RowCaption(row.caption, warns: row.captionWarns).lineLimit(1) }
                    .buttonStyle(.plain)
            }
        }
        .frame(height: scale(Size.chip))
    }

    /// The line as VoiceOver reads it: the count in words.
    static func spoken(_ row: OperationRow) -> String {
        row.showsProgress && row.attention > 0 ? "\(row.caption), \(row.attention) waiting on you" : row.caption
    }
}
