import SwiftUI
import AiTermUI
import AiTermCore

/// Projects and signals share their fold, mark, title and counts on the same grid.
struct HeadingRow: View, Equatable {
    let value: HeadingValue
    let controller: AppController
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value && lhs.controller === rhs.controller }
    @Environment(\.interfaceScale) private var scale
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    var collapses: Bool { !value.empty && controller.canChangeWorkspace }

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(value.id)
        #endif
        let selected = controller.focus.isSelected(value.id)
        let commands = commands()
        HStack(spacing: scale(Space.base)) {
            HStack(spacing: scale(Space.base)) {
                HeaderChevron(collapsed: value.collapsed).frame(width: SidebarRowLayout.chevronWidth(scale))
                    .opacity(value.empty ? 0 : 1)
                ProviderIcon(value.mark)
                titleArea
                Spacer(minLength: scale(Space.tight))
                if value.collapsed { StatusCountChips(counts: value.counts, finished: value.finished) }
            }
            .modifier(FoldOnTap(enabled: collapses, selected: selected, action: toggleCollapsed))
            .modifier(RowCommandActions(groups: commands))
            trailing(commands: commands)
        }
        .frame(height: scale(Size.projectRow)).modifier(SidebarHeadingInset())
        .modifier(RowPill(selected: selected))
        .modifier(HeadingHelp(text: value.help))
        .modifier(RowCommandContextMenu(groups: commands))
        .task(id: value.id) {
            if case .project(let project, _, _) = value.kind {
                await controller.projects.loadDefaultBranchName(of: project)
            }
        }
    }

    @ViewBuilder private var titleArea: some View {
        switch value.kind {
        case .project(let project, _, _):
            HStack(spacing: scale(Space.gap)) {
                HeaderTitle(text: value.title)
                let details = controller.preferences.badgeDetails
                if let badge = ProjectJiraBadge.badge(for: project, showsCount: details.jiraProject) {
                    ProjectJiraBadgeView(badge: badge, markInk: details.markInk, canChangeWorkspace: controller.canChangeWorkspace) {
                        controller.sheets.presentJiraProjects(for: project)
                    }
                }
            }
        case .signal:
            HeaderTitle(text: value.title)
        }
    }

    @ViewBuilder private func trailing(commands: [[RowCommand]]) -> some View {
        switch value.kind {
        case .project:
            AddMenu(help: "New task, review or terminal", enabled: controller.canChangeWorkspace) {
                RowCommandMenu(groups: Array(commands.prefix(1)))
            }
        case .signal(_, _, let paused, _, _):
            Group {
                if paused { Image(systemName: "pause.fill").font(Typography.chip).foregroundStyle(Palette.tertiary) }
                else { Color.clear }
            }.frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
        }
    }

    private func toggleCollapsed() {
        switch value.kind {
        case .project(let project, _, _): controller.projects.toggleCollapsed(project)
        case .signal:
            if let section = controller.rows.signalSections.first(where: { $0.id == value.id }) { controller.toggleCollapsed(section.signal) }
        }
    }

    func commands() -> [[RowCommand]] {
        let enabled = controller.canChangeWorkspace
        switch value.kind {
        case let .project(project, canMoveUp, canMoveDown):
            let id = project.id
            var groups: [[RowCommand]] = [
                [RowCommand(title: "New Task…", enabled: enabled && project.provider != .none) {
                    if let current = controller.state.project(id: id) { controller.sheets.presentNewTask(project: current) }
                },
                 RowCommand(title: "New Review…", enabled: enabled && project.provider != .none) {
                    if let current = controller.state.project(id: id) { controller.sheets.presentNewReview(project: current) }
                },
                 RowCommand(title: "New Terminal…", enabled: enabled) {
                    if let current = controller.state.project(id: id) { controller.sheets.presentNewTerminal(project: current) }
                }],
                RowCommand.open(path: project.path),
                [RowCommand(title: "Edit Project…", enabled: enabled) {
                    if let current = controller.state.project(id: id) { controller.sheets.presentJiraProjects(for: current) }
                }]
            ]
            if project.provider == .gitlab || project.provider == .github {
                groups.append([RowCommand(title: "Pull \(controller.projects.defaultBranchName(id) ?? "Default Branch")",
                                          enabled: !controller.projects.isChangingDefaultBranch(id)) {
                    if let current = controller.state.project(id: id) { controller.projects.pullDefault(project: current) }
                }])
            }
            groups.append([
                RowCommand(title: "Move Up", enabled: enabled && canMoveUp) {
                    if controller.state.project(id: id) != nil { controller.projects.move(itemId: id, .up) }
                },
                RowCommand(title: "Move Down", enabled: enabled && canMoveDown) {
                    if controller.state.project(id: id) != nil { controller.projects.move(itemId: id, .down) }
                }
            ])
            groups.append([RowCommand(title: "Remove Project…", role: .destructive, enabled: enabled) {
                Task { if let current = controller.state.project(id: id) { await controller.projects.confirmRemove(project: current) } }
            }])
            return groups
        case let .signal(_, removed, paused, canMoveUp, canMoveDown):
            guard !removed else { return [] }
            let id = value.id
            return [
                [RowCommand(title: "Edit Signal…", enabled: controller.canPresentNewSignal) {
                    if let current = controller.state.signal(id: id) { controller.presentNewSignal(editing: current) }
                },
                 RowCommand(title: !paused ? "Switch Off" : "Switch On", enabled: enabled) {
                    if let current = controller.state.signal(id: id) { controller.toggleEnabled(current) }
                }],
                [RowCommand(title: "Move Up", enabled: enabled && canMoveUp) { controller.moveSignal(id, .up) },
                 RowCommand(title: "Move Down", enabled: enabled && canMoveDown) { controller.moveSignal(id, .down) }],
                [RowCommand(title: "Remove Signal…", role: .destructive, enabled: enabled) {
                    if let current = controller.state.signal(id: id) { controller.removeSignal(current) }
                }]
            ]
        }
    }
}

private struct HeadingHelp: ViewModifier {
    let text: String
    func body(content: Content) -> some View {
        if text.isEmpty { content } else { content.help(text) }
    }
}

/// Each section reads only its own fold and title, so unrelated status changes redraw neither.
struct SectionHeading: View {
    typealias Kind = SidebarSection
    let controller: AppController
    let kind: Kind
    @Environment(\.interfaceScale) private var scale
    @State private var hovering = false
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.countHeading(kind == .operator ? "operator" : "projects")
        #endif
        let commands = Self.commands(kind: kind, paused: kind == .operator && controller.rows.operatorPaused, controller: controller)
        let addCommands = addCommands()
        let fold = kind == .operator ? controller.rows.operatorHeading : controller.rows.projectsHeading
        let title = kind == .operator ? (controller.rows.operatorPaused ? "Operator · paused" : "Operator") : "Projects"
        HStack(spacing: scale(Space.base)) {
            SectionFoldLabel(title: title, fold: fold, hovering: hovering, commands: commands,
                             enabled: controller.canChangeWorkspace, toggle: { controller.toggleOperatorOpen() },
                             open: { controller.openSection(kind, at: $0) })
            switch kind {
            case .operator:
                AddMenu(help: "Operator actions", enabled: controller.canPresentNewSignal) {
                    RowCommandMenu(groups: addCommands)
                }
            case .projects:
                AddMenu(help: "Add project or divider", enabled: controller.canChangeWorkspace) {
                    RowCommandMenu(groups: addCommands)
                }
            }
        }
        .frame(height: scale(Size.menuRow)).modifier(SidebarHeadingInset())
        .padding(.top, scale(Space.base)).padding(.bottom, scale(Space.tight))
        .onHover { hovering = $0 }
        .modifier(RowCommandContextMenu(groups: commands))
    }

    static func commands(kind: Kind, paused: Bool, controller: AppController) -> [[RowCommand]] {
        guard kind == .operator else { return [] }
        return [[RowCommand(title: paused ? "Resume Operator" : "Pause Operator", enabled: controller.canChangeWorkspace) {
            Task { await controller.signalController.setPaused(!controller.rows.operatorPaused) }
        }]]
    }

    func addCommands() -> [[RowCommand]] {
        switch kind {
        case .operator:
            [[RowCommand(title: "New Signal…", enabled: controller.canPresentNewSignal) { controller.presentNewSignal() }]]
        case .projects:
            [[RowCommand(title: "Add Project…", enabled: controller.canChangeWorkspace) { Task { await controller.projects.addProject() } },
              RowCommand(title: "Add Divider…", enabled: controller.canChangeWorkspace) { controller.sheets.presentNewDivider() }]]
        }
    }
}

/// The OPERATOR or PROJECTS heading's words, and, while the two fold into each other, one open at a time:
/// the click that switches, a macOS sidebar section's chevron (`SectionFoldChevron`), and, folded, its chips:
/// PROJECTS its rows' status counts as a folded project's header draws them, OPERATOR the Operator's own chip and
/// its finished tasks'; each chip opens the section at the row it stands for. Only the label folds; the heading's "+" keeps its own click.
///
/// The words are VoiceOver's one element for the heading, with its fold and `commands`; the chips sit beside it, not
/// in it, so each stays a button of its own rather than being combined into the heading.
struct SectionFoldLabel: View {
    let title: String
    let fold: SectionFold
    let hovering: Bool
    var commands: [[RowCommand]] = []
    let enabled: Bool
    let toggle: () -> Void
    let open: (ChipTarget) -> Void
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        let folds = fold.folds && enabled
        HStack(spacing: scale(Space.base)) {
            HStack(spacing: scale(Space.base)) {
                SidebarHeading(title)
                Spacer(minLength: scale(Space.tight))
            }
            .modifier(FoldOnTap(enabled: folds, action: toggle))
            .accessibilityLabel(title)
            .accessibilityValue(fold.folded ? "folded" : "")
            .modifier(RowCommandActions(groups: commands))
            if fold.folds {
                if fold.folded { StatusCountChips(counts: fold.counts, lead: fold.operatorChip, finished: fold.finished, open: open) }
                SectionFoldChevron(folded: fold.folded, hovering: hovering)
                    .contentShape(Rectangle())
                    .onTapGesture { if folds { toggle() } }
            }
        }
    }
}

/// A section heading's disclosure chevron while the Operator's section and the projects fold into each other: a
/// macOS sidebar section's, in the trailing column before the heading's "+", shown folded and, open, only under
/// the pointer. The heading's click folds; the chevron is not a control of its own.
struct SectionFoldChevron: View {
    let folded: Bool
    let hovering: Bool
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HeaderChevron(collapsed: folded)
            .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
            .opacity(folded || hovering ? 1 : 0)
            .accessibilityHidden(true)
    }
}

/// A project header's disclosure chevron, in its surface's secondary ink.
struct HeaderChevron: View {
    let collapsed: Bool
    @Environment(\.surface) private var surface

    var body: some View {
        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
            .font(Typography.micro).foregroundStyle(surface.secondaryInk)
    }
}

/// A project header's name, in its surface's ink — white on the selection.
struct HeaderTitle: View {
    let text: String
    @Environment(\.surface) private var surface

    var body: some View {
        Text(text).font(Typography.bodyEmphasis).foregroundStyle(surface.ink)
            .lineLimit(1).truncationMode(.tail)
    }
}

/// A quiet Jira mark and total count opening every linked project in one menu. The final
/// "Edit Project…" action is disabled while the workspace is locked; links remain available.
private struct ProjectJiraBadgeView: View {
    let badge: ProjectJiraBadge
    let markInk: Badge.MarkInk
    let canChangeWorkspace: Bool
    let editProjects: () -> Void
    var body: some View {
        Badge(badge.label, icon: .brand(Palette.jira), help: badge.help, style: .quiet, markInk: markInk,
              accessibilityLabel: badge.accessibilityLabel) {
            ForEach(badge.items, id: \.url) { item in
                Button(item.title) { ExternalApps.open(link: item.url.absoluteString) }
            }
            Divider()
            Button("Edit Project…", action: editProjects).disabled(!canChangeWorkspace)
        }
    }
}

/// A header's mark, centred in a ``Size/avatar`` square so the name after it lines up with the avatars in
/// the rows below: a project's provider, or the Operator's glyph (`IconSource` alone). No tile behind it:
/// the header sits on the sidebar's own ground. A vendor's mark is drawn at ``logoSize`` in its colour, an
/// SF Symbol at ``glyphSize`` in the surface's secondary ink.
struct ProviderIcon: View {
    let source: IconSource
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    init(provider: Provider) { source = Self.source(of: provider) }
    init(_ source: IconSource) { self.source = source }

    /// A project's host as its header marks it, and New Signal's pickers with it.
    nonisolated static func source(of provider: Provider) -> IconSource {
        switch provider {
        case .gitlab: .gitlabTanuki
        case .github: .brand(Palette.github)
        case .git: .symbol("arrow.triangle.branch")
        case .none: .symbol("folder.fill")
        }
    }

    /// A signal's Start trigger source as its heading marks it.
    nonisolated static func source(of source: SignalTrigger.Source) -> IconSource {
        switch source {
        case .jira: .brand(Palette.jira)
        case .gitLab: .gitlabTanuki
        case .gitHub: .brand(Palette.github)
        case .unknown: .symbol("questionmark.circle")
        }
    }

    /// The GitLab and GitHub marks' drawn size, inside the ``Size/avatar`` square — neither `Size` nor
    /// `Typography` has a step this close without visibly shrinking or enlarging the logo.
    private static let logoSize: CGFloat = 13
    /// The plain SF Symbol fallbacks (no vendor mark): smaller than ``logoSize`` because a system
    /// glyph reads bigger than a custom logo at the same point size.
    private static let glyphSize: CGFloat = 10
    var body: some View {
        ZStack {
            switch source {
            case .symbol: Icon(source, size: scale(Self.glyphSize), tint: surface.secondaryInk)
            case .brand, .artwork: Icon(source, size: scale(Self.logoSize))
            }
        }.frame(width: scale(Size.avatar), height: scale(Size.avatar))
    }
}
