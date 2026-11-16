import SwiftUI
import AiTermUI
import AiTermCore

/// OPERATOR, above PROJECTS, and its "+" that adds a signal. While it has anything to show — a signal or
/// its row — it folds into PROJECTS and back (`SectionFoldLabel`), folded by default: the Operator is
/// something you set up, the projects what everyone uses.
struct SignalOperatorHeading: View {
    let controller: AppController
    @Environment(\.interfaceScale) private var scale
    @State private var hovering = false
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif
    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.countHeading("operator")
        #endif
        HStack(spacing: scale(Space.base)) {
            SectionFoldLabel(title: controller.rows.operatorPaused ? "Operator · paused" : "Operator", fold: controller.rows.operatorHeading, hovering: hovering,
                             enabled: controller.canChangeWorkspace, toggle: { controller.toggleOperatorOpen() },
                             openAttention: { controller.openOperatorAttention() })
            AddMenu(help: "Operator actions", enabled: controller.canPresentNewSignal) {
                Button("New Signal…") { controller.presentNewSignal() }
                Divider()
                Button(controller.rows.operatorPaused ? "Resume Operator" : "Pause Operator") {
                    Task { await controller.signalController.setPaused(!controller.rows.operatorPaused) }
                }
            }
        }
        .frame(height: scale(Size.menuRow)).modifier(SidebarHeadingInset())
        .padding(.top, scale(Space.base)).padding(.bottom, scale(Space.tight))
        .onHover { hovering = $0 }
    }
}

/// The active workload’s row uses the same avatar, title, caption and trailing-mark grid as a task.
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
                    OperatorActivityCaption(line: line, completed: value.completedActivity, event: value.event)
                }.layoutPriority(1)
            } mark: {
                TaskRowMarkView(mark: TaskRowMark(status: status, line: line, removing: false, paused: value.paused), size: SidebarRowLayout.trailingGlyph(scale))
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

struct SignalHeader: View, Equatable {
    let heading: SignalHeadingValue
    let controller: AppController
    init(section: SignalSection, controller: AppController) { heading = SignalHeadingValue(section); self.controller = controller }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.heading == rhs.heading && lhs.controller === rhs.controller }
    @Environment(\.interfaceScale) private var scale
    @State private var starts: Int?
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif
    private var mark: IconSource {
        switch heading.source {
        case .jira: .brand(Palette.jira)
        case .gitLab: .gitlabTanuki
        case .gitHub: .brand(Palette.github)
        case .unknown: .symbol("questionmark.circle")
        }
    }
    private struct Preview: Equatable { var id: UUID; var source: SignalSource; var enabled: Bool; var removed: Bool }
    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(heading.id)
        #endif
        let selected = controller.focus.isSelected(heading.id)
        HStack(spacing: scale(Space.base)) {
            HStack(spacing: scale(Space.base)) {
                HeaderChevron(collapsed: heading.collapsed).frame(width: SidebarRowLayout.chevronWidth(scale))
                    .opacity(heading.empty ? 0 : 1)
                ProviderIcon(mark)
                HeaderTitle(text: heading.name)
                Spacer(minLength: scale(Space.tight))
                if heading.collapsed { StatusCountChips(counts: heading.counts) }
            }
            .modifier(FoldOnTap(enabled: !heading.empty && controller.canChangeWorkspace, selected: selected) {
                if let section = controller.rows.signalSections.first(where: { $0.id == heading.id }) { controller.toggleCollapsed(section.signal) }
            })
            Group {
                if !heading.enabled { Image(systemName: "pause.fill").font(Typography.chip).foregroundStyle(Palette.tertiary) }
                else { Color.clear }
            }.frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
        }
        .frame(height: scale(Size.projectRow)).modifier(SidebarHeadingInset())
        .modifier(RowPill(selected: selected)).tag(heading.id).help(heading.help)
        .contextMenu {
            if !heading.removed {
                Button("Edit Signal…") { if let signal = controller.state.signal(id: heading.id) { controller.presentNewSignal(editing: signal) } }
                Button(heading.enabled ? "Switch Off" : starts.map { "Switch On (starts \($0))" } ?? "Switch On") {
                    if let signal = controller.state.signal(id: heading.id) { controller.toggleEnabled(signal) }
                }
                Divider()
                Button("Remove Signal…", role: .destructive) { if let signal = controller.state.signal(id: heading.id) { controller.removeSignal(signal) } }
            }
        }
        .disabled(!controller.canChangeWorkspace)
        .task(id: Preview(id: heading.id, source: heading.source, enabled: heading.enabled, removed: heading.removed)) {
            guard !heading.enabled, !heading.removed else { starts = nil; return }
            do {
                let links = await controller.signalController.connections()
                let read = try await links.reader(for: heading.source).poll(since: nil, full: true)
                guard read.complete, !Task.isCancelled else { return }
                starts = read.items.filter { item in
                    !ItemProjectMapper.projects(for: item.item, in: controller.state.projects).isEmpty && !controller.state.signalSeen.contains {
                        $0.signal == heading.id && $0.item.identity == item.item.identity && $0.disposition == .started && $0.isMatching
                    }
                }.count
            } catch { starts = nil }
        }
    }
}
