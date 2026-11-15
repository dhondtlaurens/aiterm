import SwiftUI
import AiTermUI
import AiTermCore

struct SignalOperatorHeading: View {
    let controller: AppController
    @Environment(\.interfaceScale) private var scale
    var body: some View {
        HStack(spacing: scale(Space.base)) {
            SidebarHeading("Operator")
            Spacer()
            AddMenu(help: "New signal", enabled: controller.canPresentNewSignal) {
                Button("New Signal…") { controller.presentNewSignal() }
            }
        }
        .frame(height: scale(Size.menuRow)).modifier(SidebarHeadingInset())
        .padding(.top, scale(Space.base)).padding(.bottom, scale(Space.tight))
    }
}

/// The permanent row uses the same avatar, title, caption and trailing-mark grid as a task.
struct SignalOperatorRow: View {
    let value: SignalOperatorRowValue
    let controller: AppController
    @Environment(\.interfaceScale) private var scale
    private var row: UUID { OperatorRow.id(of: OperatorSession.rowID) }
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif
    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(row)
        #endif
        let line = value.line, status = value.status
        SelectableRow(id: row, selected: controller.focus.isSelected(row), washed: true,
                      activate: { controller.focus.select(.operation(OperatorSession.rowID)) }) {
            SidebarRowContent(avatars: AvatarGroup(marks: [.claude], overflow: 0)) {
                VStack(alignment: .leading, spacing: scale(Space.tight)) {
                    RowTitle("Operator")
                    OperatorBadge(line: line)
                }.layoutPriority(1)
            } mark: {
                TaskRowMarkView(mark: TaskRowMark(status: status, line: line, removing: false, paused: value.paused), size: SidebarRowLayout.trailingGlyph(scale))
                    .frame(width: SidebarRowLayout.trailingSlot(scale))
            }
        }
        .help(controller.signalController.lastError ?? line.tooltip)
        .accessibilityLabel("Operator, Claude Code session")
        .accessibilityValue(line.tooltip)
    }
}

struct SignalHeader: View {
    let section: SignalSection
    let controller: AppController
    @Environment(\.interfaceScale) private var scale
    private var signal: Signal { section.signal }
    private var mark: IconSource {
        switch signal.source {
        case .jira: .brand(Palette.jira)
        case .gitLab: .gitlabTanuki
        case .gitHub: .brand(Palette.github)
        case .unknown: .symbol("questionmark.circle")
        }
    }
    private var help: String {
        let conditions: String
        switch signal.source {
        case .jira(let query): conditions = JQL.compile(query)
        case .gitLab(let query), .gitHub(let query):
            conditions = query.event == .reviewRequested ? "When you are asked to review" : "Your requests waiting on your reply or sent back to you"
        case .unknown: conditions = "This version cannot run this signal."
        }
        let skipped = controller.state.signalSeen.filter { $0.signal == signal.id && $0.disposition == .skipped }.compactMap(\.reason)
        return ([conditions] + skipped + [controller.signalController.sourceErrors[signal.id]].compactMap { $0 }).joined(separator: "\n")
    }
    var body: some View {
        HStack(spacing: scale(Space.base)) {
            HStack(spacing: scale(Space.base)) {
                HeaderChevron(collapsed: section.collapsed).frame(width: SidebarRowLayout.chevronWidth(scale))
                    .opacity(section.tasks.isEmpty ? 0 : 1)
                ProviderIcon(mark)
                HeaderTitle(text: signal.name)
                Spacer(minLength: scale(Space.tight))
                if section.collapsed { StatusCountChips(counts: SidebarModel.statusCounts(tasks: section.tasks)) }
            }
            .modifier(FoldOnTap(enabled: !section.tasks.isEmpty && controller.canChangeWorkspace) { controller.toggleCollapsed(signal) })
            Group {
                if !signal.enabled { Image(systemName: "pause.fill").font(Typography.chip).foregroundStyle(Palette.tertiary) }
                else { Color.clear }
            }.frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
        }
        .frame(height: scale(Size.projectRow)).modifier(SidebarHeadingInset())
        .help(help)
        .contextMenu {
            Button("Edit Signal…") { controller.presentNewSignal(editing: signal) }
            Button(signal.enabled ? "Switch Off" : "Switch On") { controller.toggleEnabled(signal) }
            Divider()
            Button("Remove Signal…", role: .destructive) { controller.removeSignal(signal) }
        }
        .disabled(!controller.canChangeWorkspace)
    }
}
