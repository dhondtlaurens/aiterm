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
    /// A selected project header's "+" sits on the accent.
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

/// `PROJECTS`, and the menu that adds a project or a divider. While a broadcast exists it folds into the OPERATOR
/// heading and back (`OperatorHeading`): its click switches, its chevron shows folded and, open, under the pointer,
/// and folded it says what needs you among the projects once, as an amber count, whose click opens them at the first.
struct SidebarHeader: View {
    let controller: AppController
    @Environment(\.interfaceScale) private var scale
    @State private var hovering = false

    var body: some View {
        let rows = controller.rows, folds = rows.broadcast != nil && controller.canChangeWorkspace
        HStack(spacing: scale(Space.base)) {
            HStack(spacing: scale(Space.base)) {
                SidebarHeading("Projects")
                Spacer(minLength: scale(Space.tight))
                if let broadcast = rows.broadcast {
                    let attention = rows.projectsNeedingAttention.count
                    if rows.projectsFolded, attention > 0 {
                        Button { controller.openProjectsAttention() } label: {
                            StatusCountChips(counts: [StatusCount(status: .needsInput, count: attention)])
                        }
                        .buttonStyle(.plain)
                    }
                    SectionFoldChevron(folded: !broadcast.folded, hovering: hovering)
                }
            }
            .contentShape(Rectangle())
            .gesture(TapGesture().onEnded { if let id = rows.broadcast?.id { controller.toggleFolded(run: id) } },
                     including: folds ? .all : .subviews)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Projects")
            .accessibilityValue(rows.projectsFolded ? "folded" : "")
            .accessibilityAddTraits(folds ? .isButton : [])
            .modifier(DefaultAccessibilityAction(enabled: folds) { if let id = rows.broadcast?.id { controller.toggleFolded(run: id) } })
            AddMenu(help: "Add project or divider", enabled: controller.canChangeWorkspace) {
                Button("Add Project…") { Task { await controller.addProject() } }
                Button("Add Divider…") { controller.presentNewDivider() }
            }
        }
        .frame(height: scale(Size.menuRow)).padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .padding(.top, scale(Space.base)).padding(.bottom, scale(Space.tight))
        .onHover { hovering = $0 }
    }
}

extension DividerRow {
    /// A divider wired to the workspace it belongs to.
    init(entry: DividerEntry, controller: AppController) {
        let divider = entry.divider
        self.init(entry: entry,
                  enabled: controller.canChangeWorkspace,
                  rename: { controller.presentRename(divider: divider) },
                  move: { controller.move(itemId: divider.id, $0) },
                  delete: { controller.removeDivider(divider) })
    }
}

/// A project's header: disclosure, provider, name and its Jira badge — or, collapsed, the status counts
/// of the rows it is hiding — and the menu that adds a terminal, task or review. An empty project
/// has nothing to disclose, so like a leaf in a Finder outline it draws no chevron and does not
/// toggle; the chevron's column stays, so its name lines up with its neighbours'.
///
/// The arrows stop on it, as on a row: selected, it is drawn in the same `RowPill` on
/// `Surface.accent`, and shows no window.
struct ProjectHeaderRow: View {
    let section: ProjectSection
    let controller: AppController
    @Environment(\.interfaceScale) private var scale
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    private var project: Project { section.project }
    private var collapses: Bool { Self.collapses(section, canChangeWorkspace: controller.canChangeWorkspace) }

    /// Whether the header's label collapses and expands the section — by click, and for VoiceOver as
    /// its default action and button trait. An empty project has nothing to disclose, and a locked
    /// workspace changes nothing.
    static func collapses(_ section: ProjectSection, canChangeWorkspace: Bool) -> Bool {
        !section.isEmpty && canChangeWorkspace
    }

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(project.id)
        #endif
        let selected = controller.focus.isSelected(project.id)
        HStack(spacing: scale(Space.base)) {
            // Only the label collapses the section; the "+" menu keeps its own click, which a tap
            // gesture on the whole row would have swallowed.
            HStack(spacing: scale(Space.base)) {
                HeaderChevron(collapsed: section.collapsed).frame(width: SidebarRowLayout.chevronWidth(scale))
                    .opacity(section.isEmpty ? 0 : 1)
                ProviderIcon(provider: project.provider)
                // The name, then its Jira project count, `Space.gap` apart as a task row's quiet
                // badges and branch are. They keep their width; the name is what truncates.
                HStack(spacing: scale(Space.gap)) {
                    HeaderTitle(text: project.name)
                    if let badge = ProjectJiraBadge.badge(for: project, showsCount: controller.preferences.badgeDetails.jiraProject) {
                        ProjectJiraBadgeView(badge: badge, canChangeWorkspace: controller.canChangeWorkspace) {
                            controller.presentJiraProjects(for: project)
                        }
                    }
                }
                Spacer(minLength: scale(Space.tight))
                // Only when collapsed: expanded, the task and terminal rows say all of this and more, and a
                // second copy on the header would just be noise above them.
                if section.collapsed {
                    StatusCountChips(counts: SidebarModel.statusCounts(tasks: section.tasks, terminals: section.terminals))
                }
            }
            .contentShape(Rectangle())
            // A locked workspace turns off the collapse and only that: `.subviews` keeps the Jira
            // badges' links, which change nothing and so have no reason to lock.
            .gesture(TapGesture().onEnded { controller.toggleCollapsed(project) },
                     including: collapses ? .all : .subviews)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(collapses ? .isButton : [])
            .accessibilityAddTraits(selected ? .isSelected : [])
            .modifier(DefaultAccessibilityAction(enabled: collapses) { controller.toggleCollapsed(project) })
            AddMenu(help: "New task, review or terminal", enabled: controller.canChangeWorkspace) { newItems }
        }
        .frame(height: scale(Size.projectRow)).padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .modifier(RowPill(selected: selected))
        // ↩ on an empty header opens this menu, which it has in place of a fold.
        .background(RowMenuAnchor(id: project.id))
        .contextMenu {
            // The "+" menu's items lead, greyed as they are there: the whole "+" is disabled while
            // the workspace is locked, which a context menu can only say item by item.
            Group { newItems }.disabled(!controller.canChangeWorkspace)
            Divider()
            Button("Open in Finder") { ExternalApps.openInFinder(path: project.path) }
            if ExternalApps.vscode != nil { Button("Open in VS Code") { ExternalApps.openInVSCode(path: project.path) } }
            Divider()
            Button("Jira Projects…") { controller.presentJiraProjects(for: project) }
                .disabled(!controller.canChangeWorkspace)
            Divider()
            // The git operations, a group of their own. The branch is named once a pass has read it.
            if project.provider == .gitlab || project.provider == .github {
                Button("Pull \(controller.checkouts.defaultBranch[project.id] ?? "Default Branch")") {
                    controller.pullDefault(project: project)
                }
                .disabled(controller.isChangingDefaultBranch(project.id))
                Divider()
            }
            // Disabled at the edges rather than absent: a menu that changes shape with the row's
            // position is worse than a greyed item, and this menu already greys "Remove" when locked.
            Button("Move Up") { controller.move(itemId: project.id, .up) }
                .disabled(!controller.canChangeWorkspace || !section.canMoveUp)
            Button("Move Down") { controller.move(itemId: project.id, .down) }
                .disabled(!controller.canChangeWorkspace || !section.canMoveDown)
            Divider()
            Button("Remove Project…", role: .destructive) { Task { await controller.confirmRemove(project: project) } }
                .disabled(!controller.canChangeWorkspace)
        }
    }

    /// What the "+" menu adds, shared with the context menu so the two cannot drift apart. The File
    /// menu's order.
    @ViewBuilder private var newItems: some View {
        Button("New Task…") { controller.presentNewTask(project: project) }.disabled(project.provider == .none)
        Button("New Review…") { controller.presentNewReview(project: project) }.disabled(project.provider == .none)
        Button("New Terminal…") { controller.presentNewTerminal(project: project) }
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
    // `@State` is a macro in the macOS 26 SDK and its SwiftUIMacros plugin ships only with Xcode,
    // which the pinned toolchain does not need; this is the storage the macro would generate.
    private var _hovered = State(initialValue: false)
    private var hovered: Bool {
        get { _hovered.wrappedValue }
        nonmutating set { _hovered.wrappedValue = newValue }
    }
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
/// header, and the Archive sheet's rows, which read as the sidebar's: the selection fill, else
/// the hover wash, behind the row's own padding. It declares the ground everything inside reads — `ground`
/// at rest, the sidebar's unless the pill sits on a sheet. A `washed` row, the Operator's, wears
/// `Palette.operatorRow` at rest and `Palette.badgeHovered` hovered, in the hover wash's place; selection
/// replaces either, as it does the hover.
struct RowPill: ViewModifier {
    let selected: Bool
    var hovered = false
    var washed = false
    var ground = Surface.sidebar
    @Environment(\.interfaceScale) private var scale

    /// The ground the row declares: `.hover` or `.washedHover` hovered, `.washed` at rest on the Operator's.
    static func surface(selected: Bool, hovered: Bool, washed: Bool, ground: Surface) -> Surface {
        if selected { return .accent }
        if washed { return hovered ? .washedHover : .washed }
        return hovered ? .hover : ground
    }

    /// The pill's fill, under the row's own padding.
    static func fill(selected: Bool, hovered: Bool, washed: Bool) -> Color {
        if selected { return Palette.selection }
        if washed { return hovered ? Palette.badgeHovered : Palette.operatorRow }
        return hovered ? Palette.rowHover : .clear
    }

    func body(content: Content) -> some View {
        content
            // `.hover`, not `.sidebar`, while the row is merely hovered: `AvatarGroupView`'s ring reads
            // `Surface.occludingBackground`, which is `Palette.rowHoverSolid` for `.hover` (and the washed
            // row's solids for `.washed` and `.washedHover`). Every other consumer of `surface` on a row
            // (`Badge`, `StatusMark`, `BranchLabelView`) only branches on `isOnAccent`, which these and
            // `.sidebar` share.
            .surface(Self.surface(selected: selected, hovered: hovered, washed: washed, ground: ground))
            .background(RoundedRectangle(cornerRadius: scale(Radius.control))
                .fill(Self.fill(selected: selected, hovered: hovered, washed: washed)))
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

/// One task or review: its agents, title, badges and branch, and, when there is something to say, why
/// its window could not come back, or, on a task the Operator drives, its status line as the operator
/// badge. A driven task’s menu leads with Take Over or Hand Back, and Stop Task… while it is open; a task
/// of an ended broadcast is yours, and its menu is any task's.
struct TaskRowView: View {
    let row: TaskRow
    let task: TaskItem?
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
        let removal = controller.removal(of: row.id), removing = removal?.inProgress == true
        // Stopped after its worktree went: it waits on Remove's retry, which archiving would cut short.
        let awaitsRetry = removal?.awaitsRetry == true
        let failed = controller.hasFailedRestore(row.id)
        let caption = TaskRowCaption(removal: removal, missing: missing, failed: failed)
        let folded = caption.folds(under: row.operatorLine)
        let badges = TaskRowBadges(row: row, details: controller.preferences.badgeDetails,
                                   threads: controller.reviewThreads.threads(of: row.id))
        let voiceOver = TaskRowAccessibility(title: row.title, task: task, missing: missing, failed: failed, removing: removing,
                                             awaitsRetry: awaitsRetry, queued: row.queued, canChangeWorkspace: controller.canChangeWorkspace)
        let mark = TaskRowMark(status: row.status, line: row.operatorLine, removing: removing, queued: row.queued)
        // The card lists what the background mark waits on; no other mark opens one.
        let jobs = mark == .status(.background) ? row.background : []
        // A row being removed is not activated: its window is closing, or gone.
        SelectableRow(id: row.id, selected: selected, activate: { if let task, !removing { controller.choose(task: task.id) } }) {
            HStack(spacing: scale(Space.inset)) {
                AvatarGroupView(group: row.avatars)
                VStack(alignment: .leading, spacing: scale(Space.tight)) {
                    // A queued task's title in secondary ink, as one on its way out: it has not started.
                    RowTitle(row.title, dimmed: removing || row.queued)
                    if let progress = caption.progress {
                        // In the badge line's place and at its height, so the row keeps its own.
                        HelpText(progress, fixedVerticalSize: false).frame(height: scale(Size.chip))
                    } else if !folded {
                        // Ticket, merge request, editor, then the branch — the badges in the order they
                        // are reached for, the branch last because it is the one thing that truncates.
                        // A badge never squeezes, so a row too narrow for all of them draws the fullest
                        // fit that still leaves the status mark its slot (`TaskRowBadges.fits`), ahead of
                        // the branch, which shortens in what is left.
                        HStack(spacing: 0) {
                            ViewThatFits(in: .horizontal) {
                                // "Absent, not disabled": no VS Code, no badge.
                                ForEach(badges.fits(editor: task != nil && ExternalApps.vscode != nil), id: \.self) { fit in
                                    badgeLine(fit, of: badges, beforeBranch: !row.branch.name.isEmpty)
                                }
                            }
                            .layoutPriority(1)
                            BranchLabelView(label: row.branch)
                        }
                        .transition(.opacity)
                    }
                    // Why a removal stopped, or what the task is missing, comes first; else what the
                    // Operator says of it: `queued · after PAY-232`, `Operator answering`, `done · 4f2a91c`.
                    if let note = caption.note {
                        HelpText(note.text, tone: note.warns ? .warning : .secondary, fixedVerticalSize: false).lineLimit(1)
                    } else if let line = row.operatorLine {
                        OperatorBadge(line: line)
                    }
                }
                .animation(motionStill == nil ? Motion.settle : nil, value: folded)
                Spacer(minLength: scale(Space.tight))
                // The status mark's spinner: the row's agents went with its window. An ended driven task's is the
                // check, a queued one's the pause sign. In the background, its hover opens the card.
                TaskRowMarkView(mark: mark, size: SidebarRowLayout.trailingGlyph(scale))
                    .opensBackgroundCard(slot: SidebarRowLayout.trailingSlot(scale))
            }
            .backgroundCard(jobs)
        }
        .accessibilityLabel(voiceOver.label)
        .accessibilityValue(caption.progress ?? caption.note?.text ?? row.operatorLine?.tooltip
                            ?? (jobs.isEmpty ? row.status.label : BackgroundCard(jobs: jobs).spoken))
        .accessibilityActions {
            if let task {
                ForEach(voiceOver.actions, id: \.self) { action in
                    switch action {
                    case .archive: Button(voiceOver.title(of: action)) { Task { await controller.archive(task: task) } }
                    case .remove: Button(voiceOver.title(of: action)) { Task { await controller.confirmRemove(task: task) } }
                    }
                }
            }
        }
        .accessibilityHint(Text(voiceOver.hint))
        .help(voiceOver.help)
        // The arrows step over it, as over a header: its window is closing, or gone.
        .selectionDisabled(removing)
        .contextMenu {
            if let task {
                let operatorItems = OperatorMenus.task(task.operated, broadcastLive: row.broadcastLive)
                if !operatorItems.isEmpty {
                    OperatorMenuButtons(items: operatorItems, enabled: { _ in controller.canChangeWorkspace && !removing }) {
                        controller.perform($0, on: task)
                    }
                    Divider()
                }
                Button("Rename…") { controller.presentRename(task: task) }
                    .disabled(!controller.canChangeWorkspace || removing)
                Divider()
                Button("Open in Finder") { ExternalApps.openInFinder(path: task.worktreePath) }
                if ExternalApps.vscode != nil { Button("Open in VS Code") { ExternalApps.openInVSCode(path: task.worktreePath) } }
                if let jira = task.jira { Button("Open in Jira") { ExternalApps.open(link: jira.url) } }
                Divider()
                // No ellipsis: it asks nothing unless the worktree has changes to lose.
                Button("Shelve \(task.kindName)") { Task { await controller.archive(task: task) } }
                    .disabled(!controller.canChangeWorkspace || removing || awaitsRetry)
                Button("Remove \(task.kindName)…", role: .destructive) { Task { await controller.confirmRemove(task: task) } }
                    .disabled(!controller.canChangeWorkspace || removing)
            }
        }
    }

    /// One fit of the badge line. Quiet badges carry no box, so `Space.gap` is what keeps them apart,
    /// and the last of them from the branch.
    private func badgeLine(_ fit: TaskRowBadges.Fit, of badges: TaskRowBadges, beforeBranch: Bool) -> some View {
        HStack(spacing: scale(Space.gap)) {
            if fit.ticket, let ticket = badges.ticket {
                Badge(ticket.label, icon: .brand(Palette.jira), help: ticket.help,
                      style: .quiet, action: ticket.url.map { url in { ExternalApps.open(link: url) } })
            }
            if fit.mergeRequest, let mr = badges.mergeRequest {
                Badge(mr.label, icon: .brand((mr.host ?? .gitLab).brand), help: mr.help, suffix: mr.threads,
                      style: .quiet, accessibilityLabel: mr.accessibilityLabel,
                      action: mr.url.map { url in { ExternalApps.open(link: url) } })
            }
            // Off its base it extends to `+12 −3` unless Settings has turned that off or the row is too
            // narrow, the base named only in the tooltip, which keeps the counts; a click opens the worktree.
            if fit.editor != .none, let task {
                Badge(icon: .brand(Palette.vscode), help: badges.editorHelp, diff: fit.editor == .diff ? badges.diff : nil,
                      style: .quiet) {
                    ExternalApps.openInVSCode(path: task.worktreePath)
                }
            }
        }
        .padding(.trailing, beforeBranch && !fit.wearsNone ? scale(Space.gap) : 0)
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
        SelectableRow(id: row.id, selected: selected, activate: { if let terminal { controller.focus.select(.terminal(terminal.id)) } }) {
            HStack(spacing: scale(Space.inset)) {
                AvatarGroupView(group: row.avatars)
                VStack(alignment: .leading, spacing: scale(Space.tight)) {
                    RowTitle(row.name)
                    HStack(spacing: scale(Space.gap)) {
                        if ExternalApps.vscode != nil {
                            Badge(icon: .brand(Palette.vscode), help: "Open in VS Code", style: .quiet) {
                                ExternalApps.openInVSCode(path: project.path)
                            }
                        }
                        BranchLabelView(label: row.branch).layoutPriority(1)
                    }
                }
                Spacer(minLength: scale(Space.tight))
                StatusMark(status: row.status, size: SidebarRowLayout.trailingGlyph(scale))
                    .opensBackgroundCard(slot: SidebarRowLayout.trailingSlot(scale))
            }
            .backgroundCard(row.status == .background ? row.background : [])
        }
        .accessibilityLabel(row.name)
        .accessibilityValue(row.status == .background ? BackgroundCard(jobs: row.background).spoken : row.status.label)
        .accessibilityActions {
            if let terminal {
                ForEach(TerminalRowAccessibility(canChangeWorkspace: controller.canChangeWorkspace).actions,
                        id: \.self) { action in
                    switch action {
                    case .rename: Button(action.rawValue) { controller.presentRename(terminal: terminal) }
                    case .remove: Button(action.rawValue) { controller.close(terminal: terminal) }
                    }
                }
            }
        }
        .contextMenu {
            if let terminal {
                // As a task's menu leads: the same `NameSheet`, on the terminal's name.
                Button("Rename…") { controller.presentRename(terminal: terminal) }
                    .disabled(!controller.canChangeWorkspace)
                Divider()
                Button("Open in Finder") { ExternalApps.openInFinder(path: project.path) }
                if ExternalApps.vscode != nil { Button("Open in VS Code") { ExternalApps.openInVSCode(path: project.path) } }
                Divider()
                Button("Remove Terminal", role: .destructive) { controller.close(terminal: terminal) }
                    .disabled(!controller.canChangeWorkspace)
            }
        }
    }
}

#if DEBUG
/// Counts the sidebar rows' body evaluations by row id, for the tests that hold an arrow key, a
/// removal and a missing checkout to the rows they touch. Unset everywhere else.
@MainActor
final class RowBodyCounter {
    private(set) var counts: [UUID: Int] = [:]
    func count(_ id: UUID) { counts[id, default: 0] += 1 }
    func reset() { counts = [:] }
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
/// "Jira Projects…" action is disabled while the workspace is locked; links remain available.
private struct ProjectJiraBadgeView: View {
    let badge: ProjectJiraBadge
    let canChangeWorkspace: Bool
    let editProjects: () -> Void
    var body: some View {
        Badge(badge.label, icon: .brand(Palette.jira), help: badge.help, style: .quiet,
              accessibilityLabel: badge.accessibilityLabel) {
            ForEach(badge.items, id: \.url) { item in
                Button(item.title) { ExternalApps.open(link: item.url.absoluteString) }
            }
            Divider()
            Button("Jira Projects…", action: editProjects).disabled(!canChangeWorkspace)
        }
    }
}

/// A project row's linked Jira project count and menu, testable without rendering the sidebar.
struct ProjectJiraBadge: Equatable {
    struct MenuItem: Equatable {
        let title: String
        let url: URL
    }

    /// The total count, unless the Interface tab has turned the detail off.
    let label: String?
    let help: String
    let accessibilityLabel: String
    /// Every linked project, in the order they were linked.
    let items: [MenuItem]

    /// The project's badge, or none when it links no Jira project.
    static func badge(for project: Project, showsCount: Bool = true) -> ProjectJiraBadge? {
        guard !project.jiraProjects.isEmpty else { return nil }
        return ProjectJiraBadge(jira: project.jiraProjects, showsCount: showsCount)
    }

    private init(jira: [JiraProjectRef], showsCount: Bool) {
        label = showsCount ? "\(jira.count)" : nil
        items = jira.map { .init(title: "\($0.key) · \($0.name)", url: $0.browseURL) }
        help = (["Jira"] + jira.map { "\($0.key) \($0.name)" }).joined(separator: " · ")
        accessibilityLabel = "\(jira.count) Jira \(jira.count == 1 ? "project" : "projects"): \(jira.map(\.key).sentenceList)"
    }
}

/// What VoiceOver reads and offers on a task row: its branch after its title when it has one, only
/// the actions its context menu would let the person choose now, and what choosing the row does — its
/// hint, and the tooltip: a row whose window could not be reopened tries again, unless the workspace
/// cannot change. A value, so the rule is testable without rendering the sidebar, as `TaskRowBadges` is.
struct TaskRowAccessibility: Equatable {
    enum Action: Hashable {
        case archive, remove
    }

    var label: String
    var actions: [Action]
    var hint: String
    var help: String
    /// "Task" or "Review", which Remove names as the menu does.
    private var kindName = "Task"

    /// The action as VoiceOver speaks it: the menu item's title, without its ellipsis.
    func title(of action: Action) -> String {
        switch action {
        case .archive: "Shelve \(kindName)"
        case .remove: "Remove \(kindName)"
        }
    }

    /// `awaitsRetry` is a removal that stopped after the worktree went: the row waits on Remove's retry,
    /// so Archive, which its menu greys, is not offered. `queued` is a task the Operator has not started:
    /// choosing it opens nothing, and its line's tooltip says when it starts.
    init(title: String, task: TaskItem?, missing: Bool, failed: Bool, removing: Bool = false, awaitsRetry: Bool = false,
         queued: Bool = false, canChangeWorkspace: Bool) {
        let branch = task?.branch ?? ""
        label = branch.isEmpty ? title : "\(title), \(branch)"
        let kindName = task?.kindName ?? "Task"
        self.kindName = kindName
        let words: (hint: String, help: String) =
            removing ? ("", "")
            : queued ? ("It has no window until the Operator starts it.", "")
            : missing ? ("Restore the worktree or use Remove \(kindName).", "Worktree missing. Restore it or use Remove \(kindName).")
            : failed ? canChangeWorkspace ? ("Press Return to try again.", "Couldn’t reopen its window. Click to try again.")
                                          : ("", "Couldn’t reopen its window.")
            : ("Press Return to focus the window.", "")
        hint = words.hint
        help = words.help
        guard task != nil, canChangeWorkspace, !removing else { actions = []; return }
        actions = awaitsRetry ? [.remove] : [.archive, .remove]
    }
}

/// The lines under a task row's title that are not its badges: what stands in for the badge line
/// while the row is being removed, and the caption under it — why a removal stopped, else what the
/// task is missing — its worktree, or a window that could not be reopened. While a removal runs
/// neither shows: its window closing first, and its checkout going, are the removal, not news.

/// A task row's trailing mark: its status's `StatusMark` (while the Operator holds the task, the spinner
/// unless it needs you: `SidebarModel.heldStatus`), or once the Operator's work on the task is over (its
/// line's look `ended`) the check (1A, 21 Oct 2026), or while the Operator has it queued the pause sign. The
/// check stands in for an idle session and for an unseen turn, whose last words are the Operator's to read;
/// a session at work, waiting on input or on its background work is yours again and keeps its own mark, and a
/// removal or shelving in progress spins.
enum TaskRowMark: Equatable {
    case status(TaskStatus), ended, queued

    init(status: TaskStatus, line: OperatorLine?, removing: Bool, queued: Bool = false) {
        if removing { self = .status(.working) }
        else if queued { self = .queued }
        else if line?.look == .ended, ![.working, .needsInput, .background].contains(status) { self = .ended }
        else { self = .status(status) }
    }
}

/// `TaskRowMark` drawn: the `StatusMark`; `checkmark` at the mark's size in `Palette.green`; or `pause.fill`
/// at the mark's size in `Palette.idleRing`, the idle ring's ink, since nothing runs yet. On the accent either
/// is `Palette.onAccent`, as the working arc turns there. Decorative: the row's value reads the line.
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
        case .queued:
            Icon(.symbol("pause.fill"), size: size, tint: surface.isOnAccent ? Palette.onAccent : Palette.idleRing)
                .frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}
/// The checkout or reopen failure below a task’s branch; removal progress takes precedence.
struct TaskRowCaption: Equatable {
    enum Note: Equatable {
        /// What the task is missing — its worktree, or a window that could not be reopened — in the
        /// surface's secondary ink.
        case plain(String)
        /// Why a removal stopped, in `Palette.amber` — until the row is selected.
        case warning(String)

        var text: String {
            switch self {
            case .plain(let text), .warning(let text): text
            }
        }

        var warns: Bool {
            if case .warning = self { true } else { false }
        }
    }

    /// In place of the badge line, while the row is being removed.
    var progress: String?
    var note: Note?

    /// Whether the badge line folds away under a driven task's status line `line`: while the Operator
    /// holds the task and nothing on it is yours to act on, the row is its title over that line, as tall
    /// as one of your own. A request or a publication left for you (`needsYou`) unfolds it, and so does
    /// anything this caption says, which takes the status line's place.
    func folds(under line: OperatorLine?) -> Bool {
        guard let line, progress == nil, note == nil else { return false }
        return line.look != .needsYou
    }

    init(progress: String?, note: Note?) {
        self.progress = progress
        self.note = note
    }

    /// `removal` is the row's own: whatever the banner above the list is saying meanwhile. `failed` is
    /// a restore of its window that failed; an owed window still coming back says nothing.
    init(removal: TaskRemoval?, missing: Bool, failed: Bool) {
        switch removal {
        case .removing: self.init(progress: "Removing…", note: nil)
        case .closing: self.init(progress: "Closing…", note: nil)
        case .archiving: self.init(progress: "Shelving…", note: nil)
        case .stopped(let note, _): self.init(progress: nil, note: .warning(note))
        case nil:
            if missing { self.init(progress: nil, note: .plain("Worktree missing")) }
            else if failed { self.init(progress: nil, note: .plain("Couldn’t reopen")) }
            else { self.init(progress: nil, note: nil) }
        }
    }
}

/// The actions VoiceOver offers on a terminal row: its context menu's, when they are enabled.
struct TerminalRowAccessibility: Equatable {
    /// Rename is spoken without the menu's ellipsis, as a divider's is: VoiceOver reads the action,
    /// and the sheet it opens says the rest.
    enum Action: String, Hashable {
        case rename = "Rename", remove = "Remove Terminal"
    }

    var actions: [Action]

    init(canChangeWorkspace: Bool) {
        guard canChangeWorkspace else { actions = []; return }
        actions = [.rename, .remove]
    }
}

/// The badges a task row wears, after the Interface tab's switches. A badge whose detail is off
/// keeps its mark and its link; the text it no longer prints leads its tooltip instead. A merge
/// request with a review thread that can be resolved also wears its count — `2/5` behind a bubble,
/// all resolved included — whether or not its number is switched off; one with none, or whose
/// threads have not been read, wears none.
struct TaskRowBadges: Equatable {
    struct Link: Equatable {
        var label: String?
        var help: String
        var url: String?
        var host: CodeHost? = nil
        /// The merge request's resolved review threads of all of them, behind a bubble.
        var threads: Badge.Suffix? = nil
        /// What VoiceOver reads when the badge says more than its label: the count, in words.
        var accessibilityLabel: String? = nil
    }

    /// The SF Symbol a merge request's thread count stands behind.
    static let threadsSymbol = "bubble.left"

    var ticket: Link?
    var mergeRequest: Link?
    /// The VS Code badge's `+12 −3`; `nil` draws the plain mark.
    var diff: Badge.Diff?
    /// Always names the counts when there are any, whether or not the badge prints them.
    var editorHelp: String

    /// `threads` is the row's merge request's, as last read; `nil` while there is no answer.
    init(row: TaskRow, details: BadgeDetails, threads: ReviewThreads? = nil) {
        ticket = row.jiraKey.map { key in
            details.jiraTicket
                ? Link(label: key, help: row.jiraUrl ?? key, url: row.jiraUrl)
                : Link(label: nil, help: row.jiraUrl.map { "\(key) · \($0)" } ?? key, url: row.jiraUrl)
        }
        mergeRequest = row.mr.map { mr in
            var link = details.mergeRequest
                ? Link(label: mr.reference, help: mr.title, url: mr.url, host: mr.host)
                : Link(label: nil, help: "\(mr.reference) · \(mr.title)", url: mr.url, host: mr.host)
            // Nothing until there is a thread to count; then it stays, all resolved included.
            if let threads, threads.total > 0 {
                let words = Self.words(threads)
                link.accessibilityLabel = "\(link.label ?? link.help), \(words)"
                link.help += " · \(words)"
                link.threads = Badge.Suffix(icon: .symbol(Self.threadsSymbol), text: "\(threads.resolved)/\(threads.total)")
            }
            return link
        }
        diff = details.diff ? row.diff.map { Badge.Diff(added: $0.stat.added, removed: $0.stat.removed) } : nil
        editorHelp = row.diff?.help ?? "Open in VS Code"
    }

    /// How a fit draws the VS Code badge: with its `+12 −3`, as the plain mark, or not at all.
    enum Editor: Hashable { case diff, plain, none }

    /// The badges one width of the row keeps.
    struct Fit: Hashable {
        var ticket: Bool, mergeRequest: Bool, editor: Editor
        var wearsNone: Bool { !ticket && !mergeRequest && editor == .none }
    }

    /// The badge line at every width, fullest first, each fit giving up one more thing than the last:
    /// the VS Code counts fold to the plain mark, then the editor, the merge request and the ticket drop
    /// in turn, from the end of the line, so what is left reads in the same order. Only what the row
    /// wears is given up, and the last fit wears nothing. `editor` is whether the row has a VS Code badge.
    func fits(editor: Bool) -> [Fit] {
        var fit = Fit(ticket: ticket != nil, mergeRequest: mergeRequest != nil,
                      editor: !editor ? .none : diff == nil ? .plain : .diff)
        var fits = [fit]
        func giveUp(_ change: (inout Fit) -> Void) {
            change(&fit)
            if fit != fits.last { fits.append(fit) }
        }
        giveUp { if $0.editor == .diff { $0.editor = .plain } }
        giveUp { $0.editor = .none }
        giveUp { $0.mergeRequest = false }
        giveUp { $0.ticket = false }
        return fits
    }

    /// The count as the tooltip and VoiceOver say it: "2 of 5 threads resolved", "1 of 1 thread resolved".
    static func words(_ threads: ReviewThreads) -> String {
        "\(threads.resolved) of \(threads.total) \(threads.total == 1 ? "thread" : "threads") resolved"
    }
}

/// A header's mark, centred in a ``Size/avatar`` square so the name after it lines up with the avatars in
/// the rows below: a project's provider, or a broadcast's glyph (`IconSource` alone). No tile behind it:
/// the header sits on the sidebar's own ground. A vendor's mark is drawn at ``logoSize`` in its colour, an
/// SF Symbol at ``glyphSize`` in the surface's secondary ink.
struct ProviderIcon: View {
    let source: IconSource
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    init(provider: Provider) { source = Self.source(of: provider) }
    init(_ source: IconSource) { self.source = source }

    /// A project's host as its header marks it, and New Broadcast's pickers with it.
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
