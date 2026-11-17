import SwiftUI
import AiTermUI
import AiTermCore

/// The measurements every sidebar row shares, at the scale the row is drawn at.
enum SidebarRowLayout {
    /// Everything in the sidebar's trailing column — both "+" glyphs and a row's status mark —
    /// is ~10 pt of ink centred in a 20 pt click target, so they all share one centre line.
    static func trailingGlyph(_ scale: InterfaceScale) -> CGFloat { scale(Size.trailingGlyph) }
    static func trailingSlot(_ scale: InterfaceScale) -> CGFloat { scale(Size.slot) }
    /// A row insets that *ink* by `Space.base`, matching its own leading padding, so the glyphs end
    /// where the chevron and the project title start on the left. The slot is wider than its
    /// glyph, so it overhangs the row's padding by half the difference. Worked from the scaled
    /// parts rather than scaling the ×1 result, so the glyph's edge stays on the padding line.
    static func trailingInset(_ scale: InterfaceScale) -> CGFloat {
        scale(Space.base) - (trailingSlot(scale) - trailingGlyph(scale)) / 2
    }
    /// The project row's own leading disclosure chevron width.
    static func chevronWidth(_ scale: InterfaceScale) -> CGFloat { scale(Size.chevron) }
}

/// The add glyph of the OPERATOR and PROJECTS headings and a project's header, drawn identically wherever it appears. `.borderlessButton` hands the label to
/// an AppKit pop-up button, which draws the same `Image` a point larger than a `Button` does;
/// `.button` + `.plain` keeps the menu's click and gives back the button's own rendering.
struct AddMenu<Items: View>: View {
    let help: String?
    let enabled: Bool
    @ViewBuilder let items: () -> Items
    @Environment(\.interfaceScale) private var scale
    /// A selected project header's "+" sits on the selection, in its secondary ink.
    @Environment(\.surface) private var surface

    var body: some View {
        Menu(content: items) {
            Image(systemName: "plus").font(Typography.label).foregroundStyle(surface.secondaryInk)
        }
        .disabled(!enabled)
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
        .help(help ?? "")
    }
}

/// `PROJECTS`, and the menu that adds a project or a divider. While the Operator has anything to show it
/// folds into the OPERATOR heading and back (`SectionFoldLabel`), the projects open by default.
struct SidebarHeader: View {
    let controller: AppController
    @Environment(\.interfaceScale) private var scale
    @State private var hovering = false
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.countHeading("projects")
        #endif
        HStack(spacing: scale(Space.base)) {
            SectionFoldLabel(title: "Projects", fold: controller.rows.projectsHeading, hovering: hovering,
                             enabled: controller.canChangeWorkspace, toggle: { controller.toggleOperatorOpen() },
                             openAttention: { controller.openProjectsAttention() })
            AddMenu(help: "Add project or divider", enabled: controller.canChangeWorkspace) {
                Button("Add Project…") { Task { await controller.projects.addProject() } }
                Button("Add Divider…") { controller.sheets.presentNewDivider() }
            }
        }
        .frame(height: scale(Size.menuRow)).modifier(SidebarHeadingInset())
        .padding(.top, scale(Space.base)).padding(.bottom, scale(Space.tight))
        .onHover { hovering = $0 }
    }
}

/// The OPERATOR or PROJECTS heading's words, and, while the two fold into each other, one open at a time:
/// the click that switches, a macOS sidebar section's chevron (`SectionFoldChevron`), and, folded, what
/// needs you in its section as one amber count, whose click opens the section at the first such row.
/// Only the label folds; the heading's "+" keeps its own click.
struct SectionFoldLabel: View {
    let title: String
    let fold: SectionFold
    let hovering: Bool
    let enabled: Bool
    let toggle: () -> Void
    let openAttention: () -> Void
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack(spacing: scale(Space.base)) {
            SidebarHeading(title)
            Spacer(minLength: scale(Space.tight))
            if fold.folds {
                if fold.folded, fold.attention > 0 {
                    Button(action: openAttention) {
                        StatusCountChips(counts: [StatusCount(status: .needsInput, count: fold.attention)])
                    }
                    .buttonStyle(.plain)
                }
                SectionFoldChevron(folded: fold.folded, hovering: hovering)
            }
        }
        .modifier(FoldOnTap(enabled: fold.folds && enabled, action: toggle))
        .accessibilityLabel(title)
        .accessibilityValue(fold.folded ? "folded" : "")
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

extension DividerRow {
    /// A divider wired to the workspace it belongs to.
    init(entry: DividerEntry, controller: AppController) {
        let divider = entry.divider
        self.init(entry: entry,
                  enabled: controller.canChangeWorkspace,
                  rename: { controller.sheets.presentRename(divider: divider) },
                  move: { controller.projects.move(itemId: divider.id, $0) },
                  delete: { controller.projects.removeDivider(divider) })
    }
}

/// A project's header: disclosure, provider, name and its Jira badge — or, collapsed, the status counts
/// of the rows it is hiding — and the menu that adds a terminal, task or review. An empty project
/// has nothing to disclose, so like a leaf in a Finder outline it draws no chevron and does not
/// toggle; the chevron's column stays, so its name lines up with its neighbours'.
///
/// The arrows stop on it, as on a row: selected, it is drawn in the same `RowPill` on
/// `Surface.selected`, and shows no window.
struct ProjectHeaderRow: View {
    let heading: ProjectHeadingValue
    let controller: AppController
    @Environment(\.interfaceScale) private var scale
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    init(section: ProjectSection, controller: AppController) {
        heading = ProjectHeadingValue(section); self.controller = controller
    }

    private var project: Project { heading.project }
    /// Whether the header's label collapses and expands the section — by click, and for VoiceOver as
    /// its default action and button trait. An empty project has nothing to disclose, and a locked
    /// workspace changes nothing.
    var collapses: Bool { !heading.isEmpty && controller.canChangeWorkspace }

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(project.id)
        #endif
        let selected = controller.focus.isSelected(project.id)
        HStack(spacing: scale(Space.base)) {
            // Only the label collapses the section; the "+" menu keeps its own click, which a tap
            // gesture on the whole row would have swallowed.
            HStack(spacing: scale(Space.base)) {
                HeaderChevron(collapsed: heading.collapsed).frame(width: SidebarRowLayout.chevronWidth(scale))
                    .opacity(heading.isEmpty ? 0 : 1)
                ProviderIcon(provider: project.provider)
                // The name, then its Jira project count, `Space.gap` apart as a task row's quiet
                // badges and branch are. They keep their width; the name is what truncates.
                HStack(spacing: scale(Space.gap)) {
                    HeaderTitle(text: project.name)
                    let details = controller.preferences.badgeDetails
                    if let badge = ProjectJiraBadge.badge(for: project, showsCount: details.jiraProject) {
                        ProjectJiraBadgeView(badge: badge, markInk: details.markInk, canChangeWorkspace: controller.canChangeWorkspace) {
                            controller.sheets.presentJiraProjects(for: project)
                        }
                    }
                }
                Spacer(minLength: scale(Space.tight))
                // Only when collapsed: expanded, the task and terminal rows say all of this and more, and a
                // second copy on the header would just be noise above them.
                if heading.collapsed {
                    StatusCountChips(counts: heading.counts)
                }
            }
            .modifier(FoldOnTap(enabled: collapses, selected: selected) { controller.projects.toggleCollapsed(project) })
            AddMenu(help: "New task, review or terminal", enabled: controller.canChangeWorkspace) { newItems }
        }
        .frame(height: scale(Size.projectRow)).modifier(SidebarHeadingInset())
        .modifier(RowPill(selected: selected))
        // ↩ on an empty header opens this menu, which it has in place of a fold.
        .background(RowMenuAnchor(id: project.id))
        .task(id: project.id) { await controller.projects.loadDefaultBranchName(of: project) }
        .contextMenu {
            // The "+" menu's items lead, greyed as they are there: the whole "+" is disabled while
            // the workspace is locked, which a context menu can only say item by item.
            Group { newItems }.disabled(!controller.canChangeWorkspace)
            Divider()
            Button("Open in Finder") { ExternalApps.openInFinder(path: project.path) }
            if ExternalApps.vscode != nil { Button("Open in VS Code") { ExternalApps.openInVSCode(path: project.path) } }
            Divider()
            Button("Edit Project…") { controller.sheets.presentJiraProjects(for: project) }
                .disabled(!controller.canChangeWorkspace)
            Divider()
            // The git operations, a group of their own. The branch is named once git has answered.
            if project.provider == .gitlab || project.provider == .github {
                Button("Pull \(controller.projects.defaultBranchName(project.id) ?? "Default Branch")") {
                    controller.projects.pullDefault(project: project)
                }
                .disabled(controller.projects.isChangingDefaultBranch(project.id))
                Divider()
            }
            // Disabled at the edges rather than absent: a menu that changes shape with the row's
            // position is worse than a greyed item, and this menu already greys "Remove" when locked.
            Button("Move Up") { controller.projects.move(itemId: project.id, .up) }
                .disabled(!controller.canChangeWorkspace || !heading.canMoveUp)
            Button("Move Down") { controller.projects.move(itemId: project.id, .down) }
                .disabled(!controller.canChangeWorkspace || !heading.canMoveDown)
            Divider()
            Button("Remove Project…", role: .destructive) { Task { await controller.projects.confirmRemove(project: project) } }
                .disabled(!controller.canChangeWorkspace)
        }
    }

    /// What the "+" menu adds, shared with the context menu so the two cannot drift apart. The File
    /// menu's order.
    @ViewBuilder private var newItems: some View {
        Button("New Task…") { controller.sheets.presentNewTask(project: project) }.disabled(project.provider == .none)
        Button("New Review…") { controller.sheets.presentNewReview(project: project) }.disabled(project.provider == .none)
        Button("New Terminal…") { controller.sheets.presentNewTerminal(project: project) }
    }
}

/// The pill a selectable row — a task, a terminal or the Operator's — is drawn in: its hover wash, its
/// selection fill, and the click that activates it. The hover lives here, in the row, so moving the
/// pointer redraws that row rather than the whole sidebar. `washed` is the Operator's row: its wash at
/// rest (`RowPill`).
struct SelectableRow<Content: View>: View {
    let id: UUID
    let selected: Bool
    var washed = false
    let activate: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.interfaceScale) private var scale
    @State private var hovered: Bool = false
    #if DEBUG
    @Environment(\.seededHover) private var seededHover
    #endif

    init(id: UUID, selected: Bool, washed: Bool = false, activate: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.id = id; self.selected = selected; self.washed = washed; self.activate = activate; self.content = content
    }

    /// The pointer's hover, or in a debug build a test's.
    private var drawsHover: Bool {
        #if DEBUG
        hovered || seededHover?.row == id
        #else
        hovered
        #endif
    }

    var body: some View {
        content()
            #if DEBUG
            .transformEnvironment(\.seededHover) { seed in
                if let row = seed?.row, row != id { seed = nil }
            }
            #endif
            .padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
            .padding(.vertical, scale(Space.base))
            .frame(minHeight: scale(Size.row))
            .modifier(RowPill(selected: selected, hovered: drawsHover, washed: washed))
            // The pill is inset from the project row, so the indent goes *outside* the background —
            // painting it inside made the blue run all the way to the sidebar's edge. Selection is drawn
            // here too, not by the list: AppKit's own row highlight covers the whole row rect, which is
            // 26 pt wider on the leading edge and 8 pt taller than this pill. One painter, one rectangle.
            .padding(.leading, scale(Space.section))
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture(perform: activate)
            .allowsWindowActivationEvents()
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityAction { activate() }
    }
}

/// The pill a selectable sidebar row is drawn in — a task's, a terminal's, the Operator's, a project's
/// header, and the Archive sheet's rows, which read as the sidebar's: the neutral selection
/// (`Palette.selected`, edged inside in `Palette.selectedEdge`), else the hover wash, behind the row's own
/// padding. It declares the ground everything inside reads — `ground` at rest, the sidebar's unless the
/// pill sits on a sheet; selected, `.selected` on the sidebar and `.selectedOnSheet` on a sheet. A `washed`
/// row, the Operator's, wears `Palette.operatorRow` at rest and `Palette.badgeHovered` hovered, in the
/// hover wash's place; selection replaces either, as it does the hover.
struct RowPill: ViewModifier {
    let selected: Bool
    var hovered = false
    var washed = false
    var ground = Surface.sidebar
    @Environment(\.interfaceScale) private var scale

    /// The ground the row declares: `.selected` (or `.selectedOnSheet` on a sheet) selected, `.hover` (or
    /// `.hoverOnSheet`) or `.washedHover` hovered, `.washed` at rest on the Operator's.
    static func surface(selected: Bool, hovered: Bool, washed: Bool, ground: Surface) -> Surface {
        if selected { return ground == .sheet ? .selectedOnSheet : .selected }
        if washed { return hovered ? .washedHover : .washed }
        return hovered ? (ground == .sheet ? .hoverOnSheet : .hover) : ground
    }

    /// The pill's fill, under the row's own padding.
    static func fill(selected: Bool, hovered: Bool, washed: Bool) -> Color {
        if selected { return Palette.selected }
        if washed { return hovered ? Palette.badgeHovered : Palette.operatorRow }
        return hovered ? Palette.rowHover : .clear
    }

    func body(content: Content) -> some View {
        content
            // `.hover`, not `.sidebar`, while the row is merely hovered: `AvatarGroupView`'s ring reads
            // `Surface.occludingBackground`, which is `Palette.rowHoverSolid` for `.hover` (the washed row's
            // solids for `.washed` and `.washedHover`, the selection's for `.selected`). The marks on a row
            // (`StatusMark`, `TaskRowMarkView`) and a badge's colours branch only on `isOnAccent`, which no
            // row ground is: a selected row keeps every mark's colour.
            .surface(Self.surface(selected: selected, hovered: hovered, washed: washed, ground: ground))
            .background {
                let pill = RoundedRectangle(cornerRadius: scale(Radius.control))
                pill.fill(Self.fill(selected: selected, hovered: hovered, washed: washed))
                    .overlay { if selected { pill.strokeBorder(Palette.selectedEdge, lineWidth: 1) } }
            }
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

/// A default accessibility action that is there only while `enabled`: unlike a menu item, an action
/// cannot be greyed, only left out.
struct DefaultAccessibilityAction: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled { content.accessibilityAction(.default, action) } else { content }
    }
}

/// A sidebar row's title, in its surface's ink — white on the selection — read from the ground
/// `SelectableRow` declares, not worked out from a `selected` flag. `dimmed` draws it in the
/// secondary ink, as a row on its way out has it.
struct RowTitle: View {
    let text: String
    var dimmed = false
    @Environment(\.surface) private var surface

    init(_ text: String, dimmed: Bool = false) { self.text = text; self.dimmed = dimmed }

    var body: some View {
        Text(text).font(Typography.body).foregroundStyle(dimmed ? surface.secondaryInk : surface.ink).lineLimit(1)
    }
}

/// One task or review: its agents, title, badges, branch and any window or worker status.
/// A signal's task offers Take Over; a task you own has the usual task menu.
struct TaskRowView: View {
    let row: TaskRow
    let controller: AppController
    @Environment(\.interfaceScale) private var scale
    @Environment(\.motionStill) private var motionStill
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(row.id)
        #endif
        // Each read for this row alone, so another row's selection, removal, checkout or thread count
        // redraws that row and not this one.
        let selected = controller.focus.isSelected(row.id)
        let missing = controller.checkouts.isMissing(row.id)
        let removal = controller.teardown.state(of: row.id), removing = removal?.inProgress == true
        let caption = TaskRowCaption(removal: removal, missing: missing)
        let badges = TaskRowBadges(row: row, details: controller.preferences.badgeDetails,
                                   threads: controller.reviewThreads.threads(of: row.id))
        let voiceOver = TaskRowAccessibility(row: row, missing: missing, removing: removing,
                                             canChangeWorkspace: controller.canChangeWorkspace)
        // Removing or archiving spins, whatever the row's own mark.
        let mark = removing ? TaskRowMark.status(.working) : row.mark
        // The same work card is inspectable while the agent works or asks for input, including
        // driven rows. A removal spinner offers no card.
        let jobs = removing ? [] : row.background
        // A row being removed is not activated: its window is closing, or gone.
        SelectableRow(id: row.id, selected: selected, activate: { if !removing { controller.choose(task: row.id) } }) {
            SidebarRowContent(avatars: row.avatars) {
                VStack(alignment: .leading, spacing: scale(Space.tight)) {
                    RowTitle(row.title, dimmed: removing)
                    if let progress = caption.progress {
                        // In the badge line's place and at its height, so the row keeps its own.
                        HelpText(progress, fixedVerticalSize: false).frame(height: scale(Size.chip))
                    } else {
                        // Ticket, merge request, editor, then the branch — the badges in the order they
                        // are reached for, the branch last because it is the one thing that truncates.
                        // A badge never squeezes, so a row too narrow for all of them draws the fullest
                        // fit that still leaves the status mark its slot (`TaskRowBadges.fits`), ahead of
                        // the branch, which shortens in what is left.
                        HStack(spacing: 0) {
                            ViewThatFits(in: .horizontal) {
                                // "Absent, not disabled": no VS Code, no badge.
                                ForEach(badges.fits(editor: ExternalApps.vscode != nil), id: \.self) { fit in
                                    badgeLine(fit, of: badges, beforeBranch: !row.branch.name.isEmpty)
                                }
                            }
                            .layoutPriority(1)
                            BranchLabelView(label: row.branch)
                        }
                    }
                    // Error captions follow the same rules under projects and signals.
                    if let note = caption.note {
                        HelpText(note.text, tone: note.warns ? .warning : .secondary, fixedVerticalSize: false).lineLimit(1)
                    }
                }
            } mark: {
                // The status mark's spinner: the row's agents went with its window. An ended driven task's is the
                // check, a paused one's the pause sign. Known work opens the same card on hover.
                TaskRowMarkView(mark: mark, size: SidebarRowLayout.trailingGlyph(scale))
                    .opensBackgroundCard(slot: SidebarRowLayout.trailingSlot(scale))
            }
            .backgroundCard(jobs)
        }
        .accessibilityLabel(voiceOver.label)
        .accessibilityValue(BackgroundCard(jobs: jobs).accessibilityValue(status: row.status,
                            detail: caption.progress ?? caption.note?.text ?? row.operatorLine?.tooltip))
        .accessibilityActions {
            ForEach(voiceOver.actions, id: \.self) { action in
                switch action {
                case .archive: Button(voiceOver.title(of: action)) { archive() }
                case .remove: Button(voiceOver.title(of: action)) { remove() }
                }
            }
        }
        .accessibilityHint(Text(voiceOver.hint))
        .help(voiceOver.help)
        // The arrows step over it, as over a header: its window is closing, or gone.
        .selectionDisabled(removing)
        .contextMenu {
            if row.underOperator {
                Button("Take Over") { Task { await controller.takeOver(row.id) } }
                    .disabled(!controller.canChangeWorkspace || removing)
                Divider()
            }
            Button("Rename…") { if let current = controller.state.task(id: row.id) { controller.sheets.presentRename(task: current) } }
                .disabled(!controller.canChangeWorkspace || removing)
            Divider()
            Button("Open in Finder") { ExternalApps.openInFinder(path: row.worktreePath) }
            if ExternalApps.vscode != nil { Button("Open in VS Code") { ExternalApps.openInVSCode(path: row.worktreePath) } }
            if let url = row.jiraUrl {
                Button(row.ticketIsGitLabIssue ? "Open in GitLab" : "Open in Jira") { ExternalApps.open(link: url) }
            }
            Divider()
            // No ellipsis: it asks nothing unless the worktree has changes to lose.
            Button("Archive \(row.kindName)") { archive() }
                .disabled(!controller.canChangeWorkspace || removing)
            Button("Remove \(row.kindName)…", role: .destructive) { remove() }
                .disabled(!controller.canChangeWorkspace || removing)
        }
    }

    /// The task as it is when chosen: nothing, once it is gone.
    private func archive() {
        Task { if let current = controller.state.task(id: row.id) { try? await controller.teardown.archive(current, consent: .ask) } }
    }

    private func remove() {
        Task { if let current = controller.state.task(id: row.id) { try? await controller.teardown.remove(current, consent: .ask) } }
    }

    /// One fit of the badge line. Quiet badges carry no box, so `Space.gap` is what keeps them apart,
    /// and the last of them from the branch.
    private func badgeLine(_ fit: TaskRowBadges.Fit, of badges: TaskRowBadges, beforeBranch: Bool) -> some View {
        HStack(spacing: scale(Space.gap)) {
            QuietBadgeLine(ticket: fit.ticket ? badges.ticket.map { badgeValue($0, ticket: true, markInk: badges.markInk) } : nil,
                           request: fit.mergeRequest ? badges.mergeRequest.map { badgeValue($0, ticket: false, markInk: badges.markInk) } : nil,
                           sharesMark: badges.sharesGitLabMark)
            // Off its base it extends to `+12 −3` unless Settings has turned that off or the row is too
            // narrow, the base named only in the tooltip, which keeps the counts; a click opens the worktree.
            if fit.editor != .none {
                Badge(icon: .brand(Palette.vscode), help: badges.editorHelp, diff: fit.editor == .diff ? badges.diff : nil,
                      style: .quiet, markInk: badges.markInk) {
                    ExternalApps.openInVSCode(path: row.worktreePath)
                }
            }
        }
        .padding(.trailing, beforeBranch && !fit.wearsNone ? scale(Space.gap) : 0)
    }

    private func badgeValue(_ link: TaskRowBadges.Link, ticket: Bool, markInk: Badge.MarkInk) -> QuietBadgeValue {
        QuietBadgeValue(label: link.label,
                        icon: .brand(ticket ? (link.host == .gitLab ? Palette.gitlab : Palette.jira) : (link.host ?? .gitLab).brand),
                        help: link.help, suffix: link.threads, accessibilityLabel: link.accessibilityLabel,
                        markInk: markInk, action: link.url.map { url in { ExternalApps.open(link: url) } })
    }

}

/// A terminal is selectable exactly like a task and drawn like one: two lines, the branch on its own
/// line behind the VS Code badge. Its avatars and status mark are live too: they follow whatever is
/// running in the terminal's own window — the model substitutes a single shell mark when there are
/// no agent sessions.
struct TerminalRowView: View {
    let row: TerminalRow
    let terminal: TerminalItem?
    let project: Project
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
        SelectableRow(id: row.id, selected: selected, activate: { if let terminal { controller.choose(.terminal(terminal.id)) } }) {
            SidebarRowContent(avatars: row.avatars) {
                VStack(alignment: .leading, spacing: scale(Space.tight)) {
                    RowTitle(row.name)
                    HStack(spacing: scale(Space.gap)) {
                        if ExternalApps.vscode != nil {
                            Badge(icon: .brand(Palette.vscode), help: "Open in VS Code", style: .quiet,
                                  markInk: controller.preferences.badgeDetails.markInk) {
                                ExternalApps.openInVSCode(path: project.path)
                            }
                        }
                        BranchLabelView(label: row.branch).layoutPriority(1)
                    }
                }
            } mark: {
                StatusMark(status: row.status, size: SidebarRowLayout.trailingGlyph(scale))
                    .opensBackgroundCard(slot: SidebarRowLayout.trailingSlot(scale))
            }
            .backgroundCard(row.background)
        }
        .accessibilityLabel(row.name)
        .accessibilityValue(BackgroundCard(jobs: row.background).accessibilityValue(status: row.status))
        .accessibilityActions {
            if let terminal {
                ForEach(TerminalRowAccessibility(canChangeWorkspace: controller.canChangeWorkspace).actions,
                        id: \.self) { action in
                    switch action {
                    case .rename: Button(action.rawValue) { controller.sheets.presentRename(terminal: terminal) }
                    case .remove: Button(action.rawValue) { controller.terminals.close(terminal: terminal) }
                    }
                }
            }
        }
        .contextMenu {
            if let terminal {
                // As a task's menu leads: the same `NameSheet`, on the terminal's name.
                Button("Rename…") { controller.sheets.presentRename(terminal: terminal) }
                    .disabled(!controller.canChangeWorkspace)
                Divider()
                Button("Open in Finder") { ExternalApps.openInFinder(path: project.path) }
                if ExternalApps.vscode != nil { Button("Open in VS Code") { ExternalApps.openInVSCode(path: project.path) } }
                Divider()
                Button("Remove Terminal", role: .destructive) { controller.terminals.close(terminal: terminal) }
                    .disabled(!controller.canChangeWorkspace)
            }
        }
    }
}

#if DEBUG
/// Counts row and section-heading bodies for hosted work budgets. Each test host supplies
/// its own counter; normal app presentations leave it unset.
@MainActor
final class RowBodyCounter {
    private(set) var counts: [UUID: Int] = [:]
    private(set) var headings: [String: Int] = [:]
    func count(_ id: UUID) { counts[id, default: 0] += 1 }
    func countHeading(_ name: String) { headings[name, default: 0] += 1 }
    func reset() { counts = [:]; headings = [:] }
}

private struct RowBodyCounterKey: EnvironmentKey { static let defaultValue: RowBodyCounter? = nil }

extension EnvironmentValues {
    var rowBodyCounter: RowBodyCounter? {
        get { self[RowBodyCounterKey.self] }
        set { self[RowBodyCounterKey.self] = newValue }
    }
}

/// A debug fixture can paint a row's hover by identity, or pass the real background-card hover
/// state to a directly hosted row. Seeding the pill alone never opens the card.
struct SeededHover {
    var row: UUID? = nil
    var backgroundCard: BackgroundCardHover? = nil
}

private struct SeededHoverKey: EnvironmentKey { static let defaultValue: SeededHover? = nil }

extension EnvironmentValues {
    var seededHover: SeededHover? {
        get { self[SeededHoverKey.self] }
        set { self[SeededHoverKey.self] = newValue }
    }
}
#endif

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

/// `TaskRowMark` drawn: the `StatusMark`; `checkmark` at the mark's size in `Palette.green`; or `pause.fill`
/// at the mark's size in `Palette.idleRing`, the idle ring's ink, since nothing runs yet. On the accent either
/// is `Palette.onAccent`, as the working arc turns there; a selected row is neutral, so both keep their
/// colours. Decorative: the row's value reads the line.
struct TaskRowMarkView: View {
    let mark: TaskRowMark
    let size: CGFloat
    @Environment(\.surface) private var surface

    var body: some View {
        switch mark {
        case .status(let status): StatusMark(status: status, size: size)
        case .ended:
            Icon(.symbol("checkmark"), size: size, tint: surface.isOnAccent ? Palette.onAccent : Palette.green)
                .frame(width: size, height: size).accessibilityHidden(true)
        case .pauseSign:
            Icon(.symbol("pause.fill"), size: size, tint: surface.isOnAccent ? Palette.onAccent : Palette.idleRing)
                .frame(width: size, height: size).accessibilityHidden(true)
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
    static func source(of provider: Provider) -> IconSource {
        switch provider {
        case .gitlab: .gitlabTanuki
        case .github: .brand(Palette.github)
        case .git: .symbol("arrow.triangle.branch")
        case .none: .symbol("folder.fill")
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
