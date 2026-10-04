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

/// The add glyph, drawn identically wherever it appears. `.borderlessButton` hands the label to
/// an AppKit pop-up button, which draws the same `Image` a point larger than a `Button` does;
/// `.button` + `.plain` keeps the menu's click and gives back the button's own rendering.
private struct AddMenu<Items: View>: View {
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

/// `PROJECTS`, Backpack Mode's glyph, and the menu that adds a project or a divider.
struct SidebarHeader: View {
    let controller: AppController
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack {
            SidebarHeading("Projects")
            Spacer()
            BackpackHeaderButton(backpack: controller.backpack, openSettings: { controller.presentSettings(tab: .backpack) })
            AddMenu(help: "Add project or divider", enabled: controller.canChangeWorkspace) {
                Button("Add Project…") { controller.addProject() }
                Button("Add Divider…") { controller.presentNewDivider() }
            }
        }
        .frame(height: scale(Size.menuRow)).padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .padding(.top, scale(Space.base)).padding(.bottom, scale(Space.tight))
    }
}

/// How the Backpack glyph is drawn.
enum BackpackGlyphLook: Equatable { case off, busy, on, degraded }

/// Backpack Mode's glyph in the PROJECTS header, always there: the trailing column's ink in a
/// `Size.slot`, as the "+" beside it is — the "+"'s grey while off, `StatusMark`'s spinner while it
/// turns on or off, the accent while on, amber while it needs the person. A click opens its menu,
/// as the "+" does: the state in a line, the toggle, and the settings. Built like `AddMenu`, for the
/// same rendering.
struct BackpackHeaderButton: View {
    let backpack: BackpackController
    let openSettings: () -> Void
    @Environment(\.interfaceScale) private var scale

    /// Away from the desk. Also the Backpack toasts' symbol.
    static let symbol = "figure.walk"

    static func look(state: BackpackState, transition: BackpackTransition?) -> BackpackGlyphLook {
        if transition != nil { return .busy }
        guard case .on(let status) = state else { return .off }
        return status.degraded ? .degraded : .on
    }

    /// The glyph's ink; `.busy` draws the spinner instead, in its own.
    static func ink(for look: BackpackGlyphLook) -> Color {
        switch look {
        case .off, .busy: Palette.muted
        case .on: Palette.accent
        case .degraded: Palette.amber
        }
    }

    static func toggleTitle(isOn: Bool) -> String { isOn ? "Turn Off Backpack Mode" : "Turn On Backpack Mode" }

    /// While setup is missing, the settings lead: the toggle would only answer "needs setup".
    static func settingsFirst(state: BackpackState, setup: BackpackSetup) -> Bool { !state.isOn && !setup.isComplete }

    var body: some View {
        let look = Self.look(state: backpack.state, transition: backpack.transition)
        let line = BackpackPresentation.menuLine(state: backpack.state, setup: backpack.setup)
        Menu {
            Text(line)
            Divider()
            if Self.settingsFirst(state: backpack.state, setup: backpack.setup) {
                Button("Backpack Settings…", action: openSettings)
                toggle
            } else {
                toggle
                Button("Backpack Settings…", action: openSettings)
            }
        } label: {
            if look == .busy {
                StatusMark(status: .working, size: SidebarRowLayout.trailingGlyph(scale))
            } else {
                Icon(.symbol(Self.symbol), size: SidebarRowLayout.trailingGlyph(scale), tint: Self.ink(for: look))
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
        .help(line)
        .accessibilityLabel(line)
    }

    private var toggle: some View {
        Button(Self.toggleTitle(isOn: backpack.isOn)) { backpack.toggle() }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(backpack.busy)
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

/// A project's header: disclosure, provider, name and Jira badges — or, collapsed, the status counts
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

    private var project: Project { section.project }
    private var collapses: Bool { Self.collapses(section, canChangeWorkspace: controller.canChangeWorkspace) }

    /// Whether the header's label collapses and expands the section — by click, and for VoiceOver as
    /// its default action and button trait. An empty project has nothing to disclose, and a locked
    /// workspace changes nothing.
    static func collapses(_ section: ProjectSection, canChangeWorkspace: Bool) -> Bool {
        !section.isEmpty && canChangeWorkspace
    }

    var body: some View {
        let selected = controller.focus.selectedProjectId == project.id
        HStack(spacing: scale(Space.base)) {
            // Only the label collapses the section; the "+" menu keeps its own click, which a tap
            // gesture on the whole row would have swallowed.
            HStack(spacing: scale(Space.base)) {
                HeaderChevron(collapsed: section.collapsed).frame(width: SidebarRowLayout.chevronWidth(scale))
                    .opacity(section.isEmpty ? 0 : 1)
                ProviderIcon(provider: project.provider)
                // The name, then one badge per linked Jira project, all `Space.gap` apart as a task
                // row's quiet badges and branch are: the name's gap to the first badge is the same as
                // one badge's gap to the next. They keep their width; the name is what truncates.
                HStack(spacing: scale(Space.gap)) {
                    HeaderTitle(text: project.name)
                    ForEach(ProjectJiraBadge.badges(for: project, showsKey: controller.preferences.badgeDetails.jiraProject),
                            id: \.key) { badge in
                        Badge(badge.label, icon: .brand(Palette.jira), help: badge.help,
                              style: .quiet, action: { ExternalApps.open(link: badge.url.absoluteString) })
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
                .disabled(controller.changingDefaultBranch.contains(project.id))
                Divider()
            }
            // Disabled at the edges rather than absent: a menu that changes shape with the row's
            // position is worse than a greyed item, and this menu already greys "Remove" when locked.
            Button("Move Up") { controller.move(itemId: project.id, .up) }
                .disabled(!controller.canChangeWorkspace || !section.canMoveUp)
            Button("Move Down") { controller.move(itemId: project.id, .down) }
                .disabled(!controller.canChangeWorkspace || !section.canMoveDown)
            Divider()
            Button("Remove Project…", role: .destructive) { controller.confirmRemove(project: project) }
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

/// The pill a selectable row — a task or a terminal — is drawn in: its hover wash, its selection
/// fill, and the click that activates it. The hover lives here, in the row, so moving the pointer
/// redraws that row rather than the whole sidebar.
struct SelectableRow<Content: View>: View {
    let selected: Bool
    let activate: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.interfaceScale) private var scale
    // `@State` is a macro in the macOS 26 SDK and its SwiftUIMacros plugin ships only with Xcode,
    // which the pinned toolchain does not need; this is the storage the macro would generate.
    var _hovered: State<Bool>
    private var hovered: Bool {
        get { _hovered.wrappedValue }
        nonmutating set { _hovered.wrappedValue = newValue }
    }

    /// `hovered` seeds the pointer state, for tests and snapshots that draw a hovered row.
    init(selected: Bool, hovered: Bool = false, activate: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.selected = selected; self.activate = activate; self.content = content
        _hovered = State(initialValue: hovered)
    }

    var body: some View {
        content()
            .padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
            .padding(.vertical, scale(Space.base))
            .frame(minHeight: scale(Size.row))
            .modifier(RowPill(selected: selected, hovered: hovered))
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

/// The pill a selectable sidebar row is drawn in — a task's, a terminal's, a project header's: the
/// selection fill, else the hover wash, behind the row's own padding. It declares the ground
/// everything inside reads.
struct RowPill: ViewModifier {
    let selected: Bool
    var hovered = false
    @Environment(\.interfaceScale) private var scale

    func body(content: Content) -> some View {
        content
            // `.hover`, not `.sidebar`, while the row is merely hovered: `AvatarGroupView`'s ring reads
            // `Surface.occludingBackground`, which is `Palette.rowHoverSolid` for `.hover`. Every other
            // consumer of `surface` on a row (`Badge`, `StatusMark`, `BranchLabelView`) only branches on
            // `isOnAccent`, which `.hover` and `.sidebar` share.
            .surface(selected ? .accent : (hovered ? .hover : .sidebar))
            .background(RoundedRectangle(cornerRadius: scale(Radius.control))
                .fill(selected ? Palette.selection : (hovered ? Palette.rowHover : .clear)))
    }
}

/// A project header's disclosure chevron, in its surface's secondary ink.
private struct HeaderChevron: View {
    let collapsed: Bool
    @Environment(\.surface) private var surface

    var body: some View {
        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
            .font(Typography.micro).foregroundStyle(surface.secondaryInk)
    }
}

/// A project header's name, in its surface's ink — white on the selection.
private struct HeaderTitle: View {
    let text: String
    @Environment(\.surface) private var surface

    var body: some View {
        Text(text).font(Typography.bodyEmphasis).foregroundStyle(surface.ink)
            .lineLimit(1).truncationMode(.tail)
    }
}

/// A default accessibility action that is there only while `enabled`: unlike a menu item, an action
/// cannot be greyed, only left out.
private struct DefaultAccessibilityAction: ViewModifier {
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

/// A line under a sidebar row's title — a removal's progress, why it stopped, what the task is
/// missing — in its surface's secondary ink. `warns` is amber, except on the accent, where amber
/// does not read.
struct RowCaption: View {
    let text: String
    var warns = false
    @Environment(\.surface) private var surface

    init(_ text: String, warns: Bool = false) { self.text = text; self.warns = warns }

    var body: some View {
        Text(text).font(Typography.help).foregroundStyle(warns && !surface.isOnAccent ? Palette.amber : surface.secondaryInk)
    }
}

/// One task or review: its agents, title, badges and branch, and — when there is something to say —
/// why its window is not there.
struct TaskRowView: View {
    let row: TaskRow
    let task: TaskItem?
    var hovered = false
    let controller: AppController
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        let selected = controller.focus.selectedTaskId == row.id
        let missing = controller.checkouts.missingCheckouts.contains(row.id)
        let removal = controller.removals[row.id], removing = removal?.inProgress == true
        let caption = TaskRowCaption(removal: removal, missing: missing, windowOpen: task?.windowId != nil)
        let badges = TaskRowBadges(row: row, details: controller.preferences.badgeDetails)
        let voiceOver = TaskRowAccessibility(title: row.title, task: task, missing: missing, removing: removing,
                                             canChangeWorkspace: controller.canChangeWorkspace)
        let kindName = task?.kindName ?? "Task"
        // A row being removed is not activated: its window is closing, or gone.
        SelectableRow(selected: selected, hovered: hovered, activate: { if let task, !removing { controller.focus.select(.task(task.id)) } }) {
            HStack(spacing: scale(Space.inset)) {
                AvatarGroupView(group: row.avatars)
                VStack(alignment: .leading, spacing: scale(Space.tight)) {
                    RowTitle(row.title, dimmed: removing)
                    if let progress = caption.progress {
                        // In the badge line's place and at its height, so the row keeps its own.
                        RowCaption(progress).frame(height: scale(Size.chip))
                    } else {
                        // Ticket, merge request, editor, then the branch — the badges in the order they
                        // are reached for, the branch last because it is the one thing that truncates.
                        // Quiet badges carry no box, so `Space.gap` is what keeps them apart.
                        HStack(spacing: scale(Space.gap)) {
                            if let ticket = badges.ticket {
                                Badge(ticket.label, icon: .brand(Palette.jira), help: ticket.help,
                                      style: .quiet, action: ticket.url.map { url in { ExternalApps.open(link: url) } })
                            }
                            if let mr = badges.mergeRequest {
                                Badge(mr.label, icon: .brand((mr.host ?? .gitLab).brand), help: mr.help,
                                      style: .quiet, action: mr.url.map { url in { ExternalApps.open(link: url) } })
                            }
                            // "Absent, not disabled": no VS Code, no badge. Off its base it extends to
                            // `+12 −3` unless Settings has turned that off, the base named only in the
                            // tooltip; either way a click opens the worktree.
                            if let task, ExternalApps.vscode != nil {
                                Badge(icon: .brand(Palette.vscode), help: badges.editorHelp, diff: badges.diff, style: .quiet) {
                                    ExternalApps.openInVSCode(path: task.worktreePath)
                                }
                            }
                            BranchLabelView(label: row.branch).layoutPriority(1)
                        }
                    }
                    if let note = caption.note { RowCaption(note.text, warns: note.warns).lineLimit(1) }
                }
                Spacer(minLength: scale(Space.tight))
                // The status mark's spinner: the row's agents went with its window.
                StatusMark(status: removing ? .working : row.status, size: SidebarRowLayout.trailingGlyph(scale))
                    .frame(width: SidebarRowLayout.trailingSlot(scale))
            }
        }
        .accessibilityLabel(voiceOver.label)
        .accessibilityValue(caption.progress ?? caption.note?.text ?? row.status.label)
        .accessibilityActions {
            if let task {
                ForEach(voiceOver.actions, id: \.self) { action in
                    switch action {
                    case .reopenWindow: Button(voiceOver.title(of: action)) { controller.reopen(task: task) }
                    case .remove: Button(voiceOver.title(of: action)) { controller.confirmRemove(task: task) }
                    }
                }
            }
        }
        .accessibilityHint(removing ? Text("") : missing ? Text("Restore the worktree or use Remove \(kindName).") :
            (task?.windowId == nil ? Text("Use Reopen Window in the context menu.") : Text("Press Return to focus the window.")))
        .help(removing ? "" : missing ? "Worktree missing. Restore it or use Remove \(kindName)." :
            (task?.windowId == nil ? "Window closed. Use Reopen Window in the context menu." : ""))
        // The arrows step over it, as over a header: its window is closing, or gone.
        .selectionDisabled(removing)
        .contextMenu {
            if let task {
                Button("Rename…") { controller.presentRename(task: task) }
                    .disabled(!controller.canChangeWorkspace || removing)
                Divider()
                Button("Open in Finder") { ExternalApps.openInFinder(path: task.worktreePath) }
                if ExternalApps.vscode != nil { Button("Open in VS Code") { ExternalApps.openInVSCode(path: task.worktreePath) } }
                if let jira = task.jira { Button("Open in Jira") { ExternalApps.open(link: jira.url) } }
                Divider()
                // Ruling T13-1: "Reopen window" only when there is nothing to come back to; a task whose
                // window is still open would otherwise get a second one.
                if task.windowId == nil, !removing {
                    Button("Reopen Window") { controller.reopen(task: task) }
                        .disabled(!controller.canChangeWorkspace || missing)
                    Divider()
                }
                Button("Remove \(task.kindName)…", role: .destructive) { controller.confirmRemove(task: task) }
                    .disabled(!controller.canChangeWorkspace || removing)
            }
        }
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

    var body: some View {
        let selected = controller.focus.selectedTerminalId == row.id
        SelectableRow(selected: selected, activate: { if let terminal { controller.focus.select(.terminal(terminal.id)) } }) {
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
                StatusMark(status: row.status, size: SidebarRowLayout.trailingGlyph(scale)).frame(width: SidebarRowLayout.trailingSlot(scale))
            }
        }
        .accessibilityLabel(row.name)
        .accessibilityValue(row.status.label)
        .accessibilityActions {
            if let terminal {
                ForEach(TerminalRowAccessibility(terminal: terminal, canChangeWorkspace: controller.canChangeWorkspace).actions,
                        id: \.self) { action in
                    switch action {
                    case .rename: Button(action.rawValue) { controller.presentRename(terminal: terminal) }
                    case .reopenWindow: Button(action.rawValue) { controller.reopen(terminal: terminal, project: project) }
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
                if terminal.windowId == nil {
                    Button("Reopen Window") { controller.reopen(terminal: terminal, project: project) }
                        .disabled(!controller.canChangeWorkspace)
                    Divider()
                }
                Button("Remove Terminal", role: .destructive) { controller.close(terminal: terminal) }
                    .disabled(!controller.canChangeWorkspace)
            }
        }
    }
}

/// One of the Jira badges a project row wears beside its own name, one per linked Jira project. A
/// presentational value rather than an expression inside the row, so the rule — which badges a
/// project gets, and where each points — is testable without rendering the sidebar, the way
/// `PickerRowAppearance` is.
struct ProjectJiraBadge: Equatable {
    let key: String
    /// The key, unless the Interface tab has turned the project key off; the mark then stands alone.
    let label: String?
    let help: String
    let url: URL

    /// The project's badges, in the order its Jira projects were linked.
    static func badges(for project: Project, showsKey: Bool = true) -> [ProjectJiraBadge] {
        project.jiraProjects.map { ProjectJiraBadge(jira: $0, showsKey: showsKey) }
    }

    init(jira: JiraProjectRef, showsKey: Bool = true) {
        key = jira.key
        label = showsKey ? jira.key : nil
        url = jira.browseURL
        // The row shows the key only; the project's full name is worth a hover, and the URL beside
        // it is what every other badge in the sidebar puts there. A badge without its key names it
        // there too.
        help = "\(showsKey ? jira.name : "\(jira.name) (\(jira.key))") — \(url.absoluteString)"
    }
}

/// What VoiceOver reads and offers on a task row: its branch after its title when it has one, and
/// only the actions its context menu would let the person choose now. A value, so the rule is
/// testable without rendering the sidebar, as `TaskRowBadges` is.
struct TaskRowAccessibility: Equatable {
    enum Action: Hashable {
        case reopenWindow, remove
    }

    var label: String
    var actions: [Action]
    /// "Task" or "Review", which Remove names as the menu does.
    private var kindName = "Task"

    /// The action as VoiceOver speaks it: the menu item's title, without its ellipsis.
    func title(of action: Action) -> String {
        switch action {
        case .reopenWindow: "Reopen Window"
        case .remove: "Remove \(kindName)"
        }
    }

    init(title: String, task: TaskItem?, missing: Bool, removing: Bool = false, canChangeWorkspace: Bool) {
        let branch = task?.branch ?? ""
        label = branch.isEmpty ? title : "\(title), \(branch)"
        kindName = task?.kindName ?? "Task"
        guard let task, canChangeWorkspace, !removing else { actions = []; return }
        // Ruling T13-1, as in the menu: a window still open has nothing to reopen.
        actions = (task.windowId == nil && !missing ? [.reopenWindow] : []) + [.remove]
    }
}

/// The lines under a task row's title that are not its badges: what stands in for the badge line
/// while the row is being removed, and the caption under it — why a removal stopped, else what the
/// task is missing. While a removal runs neither shows: its window closing first, and its checkout
/// going, are the removal, not news.
struct TaskRowCaption: Equatable {
    enum Note: Equatable {
        /// What the task is missing, in the surface's secondary ink.
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

    init(progress: String?, note: Note?) {
        self.progress = progress
        self.note = note
    }

    /// `removal` is the row's own: whatever the banner above the list is saying meanwhile.
    init(removal: TaskRemoval?, missing: Bool, windowOpen: Bool) {
        switch removal {
        case .removing: self.init(progress: "Removing…", note: nil)
        case .closing: self.init(progress: "Closing…", note: nil)
        case .stopped(let note, _): self.init(progress: nil, note: .warning(note))
        case nil:
            if missing { self.init(progress: nil, note: .plain("Worktree missing")) }
            else if !windowOpen { self.init(progress: nil, note: .plain("Window closed")) }
            else { self.init(progress: nil, note: nil) }
        }
    }
}

/// The actions VoiceOver offers on a terminal row: its context menu's, when they are enabled.
struct TerminalRowAccessibility: Equatable {
    /// Rename is spoken without the menu's ellipsis, as a divider's is: VoiceOver reads the action,
    /// and the sheet it opens says the rest.
    enum Action: String, Hashable {
        case rename = "Rename", reopenWindow = "Reopen Window", remove = "Remove Terminal"
    }

    var actions: [Action]

    init(terminal: TerminalItem, canChangeWorkspace: Bool) {
        guard canChangeWorkspace else { actions = []; return }
        actions = [.rename] + (terminal.windowId == nil ? [.reopenWindow] : []) + [.remove]
    }
}

/// The badges a task row wears, after the Interface tab's switches. A badge whose detail is off
/// keeps its mark and its link; the text it no longer prints leads its tooltip instead.
struct TaskRowBadges: Equatable {
    struct Link: Equatable {
        var label: String?
        var help: String
        var url: String?
        var host: CodeHost? = nil
    }

    var ticket: Link?
    var mergeRequest: Link?
    /// The VS Code badge's `+12 −3`; `nil` draws the plain mark.
    var diff: Badge.Diff?
    /// Always names the counts when there are any, whether or not the badge prints them.
    var editorHelp: String

    init(row: TaskRow, details: BadgeDetails) {
        ticket = row.jiraKey.map { key in
            details.jiraTicket
                ? Link(label: key, help: row.jiraUrl ?? key, url: row.jiraUrl)
                : Link(label: nil, help: row.jiraUrl.map { "\(key) — \($0)" } ?? key, url: row.jiraUrl)
        }
        mergeRequest = row.mr.map { mr in
            details.mergeRequest
                ? Link(label: mr.reference, help: mr.title, url: mr.url, host: mr.host)
                : Link(label: nil, help: "\(mr.reference) — \(mr.title)", url: mr.url, host: mr.host)
        }
        diff = details.diff ? row.diff.map { Badge.Diff(added: $0.stat.added, removed: $0.stat.removed) } : nil
        editorHelp = row.diff?.help ?? "Open in VS Code"
    }
}

/// A project's provider, centred in a ``Size/avatar`` square so the name after it lines up with the
/// avatars in the rows below. No tile behind it: the header sits on the sidebar's own ground.
struct ProviderIcon: View {
    let provider: Provider
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface
    /// The GitLab and GitHub marks' drawn size, inside the ``Size/avatar`` square — neither `Size` nor
    /// `Typography` has a step this close without visibly shrinking or enlarging the logo.
    private static let logoSize: CGFloat = 13
    /// The plain SF Symbol fallbacks (no vendor mark): smaller than ``logoSize`` because a system
    /// glyph reads bigger than a custom logo at the same point size.
    private static let glyphSize: CGFloat = 10
    var body: some View {
        ZStack {
            switch provider {
            case .gitlab:
                Icon(.gitlabTanuki, size: scale(Self.logoSize))
            case .github:
                Icon(.brand(Palette.github), size: scale(Self.logoSize))
            case .git: Icon(.symbol("arrow.triangle.branch"), size: scale(Self.glyphSize), tint: surface.secondaryInk)
            case .none: Icon(.symbol("folder.fill"), size: scale(Self.glyphSize), tint: surface.secondaryInk)
            }
        }.frame(width: scale(Size.avatar), height: scale(Size.avatar))
    }
}
