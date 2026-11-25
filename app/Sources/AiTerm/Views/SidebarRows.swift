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

extension DividerRow {
    /// A divider wired to the workspace it belongs to.
    init(entry: DividerEntry, controller: AppController) {
        let divider = entry.divider
        self.init(entry: entry,
                  enabled: controller.canChangeWorkspace,
                  rename: {
                      if let current = controller.state.items.first(where: { $0.id == divider.id })?.divider {
                          controller.sheets.presentRename(divider: current)
                      }
                  },
                  move: { controller.projects.move(itemId: divider.id, $0) },
                  delete: {
                      if let current = controller.state.items.first(where: { $0.id == divider.id })?.divider {
                          controller.projects.removeDivider(current)
                      }
                  })
    }
}

extension DividerRow {
    /// A divider among the signal headings, wired to the Operator's section of the workspace.
    init(signalEntry entry: DividerEntry, controller: AppController) {
        let id = entry.divider.id
        self.init(entry: entry,
                  enabled: controller.canChangeWorkspace,
                  rename: {
                      if let current = controller.state.signalDividers.first(where: { $0.id == id }) {
                          controller.sheets.presentRename(signalDivider: SidebarDivider(id: current.id, name: current.name))
                      }
                  },
                  move: { controller.moveSignalDivider(id, $0) },
                  delete: { controller.removeSignalDivider(id) })
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

/// A whole row's tooltip, put on only when there is one. A `.help` around the row wins over every `.help` inside it,
/// an empty one included, which then shows nothing: the badges' own tooltips (a ticket's link, "Merged · …") would
/// never appear.
struct RowHelp: ViewModifier {
    let text: String
    func body(content: Content) -> some View {
        if text.isEmpty { content } else { content.help(text) }
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
    /// Tabular figures for a title whose digits change, such as the Operator row's counts.
    var tabular = false
    @Environment(\.surface) private var surface

    init(_ text: String, dimmed: Bool = false, tabular: Bool = false) { self.text = text; self.dimmed = dimmed; self.tabular = tabular }

    var body: some View {
        Text(text).font(tabular ? Typography.body.tabular : Typography.body).foregroundStyle(dimmed ? surface.secondaryInk : surface.ink).lineLimit(1)
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
        // Each read for this row alone, so another row's selection, removal, checkout, thread count or
        // done ticket redraws that row and not this one.
        let selected = controller.focus.isSelected(row.id)
        let missing = controller.checkouts.isMissing(row.id)
        let removal = controller.teardown.state(of: row.id), removing = removal?.inProgress == true
        let caption = TaskRowCaption(removal: removal, missing: missing)
        let badges = TaskRowBadges(row: row, details: controller.preferences.badgeDetails,
                                   threads: controller.reviewThreads.threads(of: row.id),
                                   ticketDone: controller.ticketsDone.isDone(row.id))
        let voiceOver = TaskRowAccessibility(row: row, missing: missing, removing: removing)
        let commands = commands(removing: removing)
        // Removing or archiving spins, whatever the row's own mark.
        let mark = removing ? TaskRowMark.status(.working) : row.mark
        // The same work card is inspectable while the agent works or asks for input, including
        // driven rows. A removal spinner offers no card.
        let jobs = BackgroundCardPresenter.eligible(row.background, source: .task(row.id), controller: controller)
        // A row being removed is not activated: its window is closing, or gone.
        let activate: () -> Void = { if !removing { controller.choose(task: row.id) } }
        SelectableRow(id: row.id, selected: selected, activate: activate) {
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
                            BranchLabelView(label: row.branch, showsHelp: false)
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
            .backgroundCard(jobs, source: .task(row.id), activate: activate, commands: commands)
        }
        .accessibilityLabel(voiceOver.label)
        .accessibilityValue(BackgroundCard(jobs: jobs).accessibilityValue(status: row.status,
                            detail: caption.progress ?? caption.note?.text ?? row.operatorLine?.tooltip))
        .modifier(RowCommandActions(groups: commands))
        .accessibilityHint(Text(voiceOver.hint))
        .modifier(RowHelp(text: voiceOver.help))
        // The arrows step over it, as over a header: its window is closing, or gone.
        .selectionDisabled(removing)
        .modifier(RowCommandContextMenu(groups: commands))
    }

    func commands(removing: Bool) -> [[RowCommand]] {
        let enabled = controller.canChangeWorkspace && !removing
        var groups: [[RowCommand]] = []
        if row.underOperator {
            groups.append([RowCommand(title: "Take Over", enabled: enabled) {
                Task { if controller.state.task(id: row.id) != nil { await controller.takeOver(row.id) } }
            }])
        }
        groups.append([RowCommand(title: "Rename…", enabled: enabled) {
            if let current = controller.state.task(id: row.id) { controller.sheets.presentRename(task: current) }
        }])
        var open = RowCommand.open(path: row.worktreePath)
        if let url = row.jiraUrl {
            open.append(RowCommand(title: row.ticketIsGitLabIssue ? "Open in GitLab" : "Open in Jira") { ExternalApps.open(link: url) })
        }
        groups.append(open)
        if !row.underOperator {
            groups.append([
                RowCommand(title: "Move Up", enabled: enabled && row.canMove(.up)) { move(.up) },
                RowCommand(title: "Move Down", enabled: enabled && row.canMove(.down)) { move(.down) }
            ])
        }
        groups.append([
            RowCommand(title: "Archive \(row.kindName)", enabled: enabled) {
                Task { if let current = controller.state.task(id: row.id) { try? await controller.teardown.archive(current, consent: .ask) } }
            },
            RowCommand(title: "Remove \(row.kindName)…", role: .destructive, enabled: enabled) {
                Task { if let current = controller.state.task(id: row.id) { try? await controller.teardown.remove(current, consent: .ask) } }
            }
        ])
        return groups
    }

    private func move(_ step: MoveStep) {
        guard controller.teardown.state(of: row.id)?.inProgress != true else { return }
        controller.projects.move(taskId: row.id, step)
    }

    /// One fit of the badge line. Quiet badges carry no box, so `Space.gap` is what keeps them apart,
    /// and the last of them from the branch.
    private func badgeLine(_ fit: TaskRowBadges.Fit, of badges: TaskRowBadges, beforeBranch: Bool) -> some View {
        HStack(spacing: scale(Space.gap)) {
            QuietBadgeLine(ticket: fit.ticket ? badges.ticket.map { QuietBadgeValue($0, ticket: true, markInk: badges.markInk) } : nil,
                           request: fit.mergeRequest ? badges.mergeRequest.map { QuietBadgeValue($0, ticket: false, markInk: badges.markInk) } : nil,
                           sharesMark: badges.sharesGitLabMark, showsHelp: false)
            // Off its base it extends to `+12 −3` unless Settings has turned that off or the row is too
            // narrow. No tooltip: the base and the counts are VoiceOver's; a click opens the worktree.
            if fit.editor != .none {
                Badge(icon: .brand(Palette.vscode), diff: fit.editor == .diff ? badges.diff : nil,
                      style: .quiet, markInk: badges.markInk, accessibilityLabel: badges.editorHelp) {
                    ExternalApps.openInVSCode(path: row.worktreePath)
                }
            }
        }
        .padding(.trailing, beforeBranch && !fit.wearsNone ? scale(Space.gap) : 0)
    }

}

extension QuietBadgeValue {
    /// A task row's ticket or merge-request link as its quiet badge: the vendor's mark, the link's words and corner,
    /// and a click that opens it.
    init(_ link: TaskRowBadges.Link, ticket: Bool, markInk: Badge.MarkInk) {
        self.init(label: link.label,
                  icon: .brand(ticket ? (link.host == .gitLab ? Palette.gitlab : Palette.jira) : (link.host ?? .gitLab).brand),
                  help: link.help, suffix: link.threads, isMerged: link.isMerged, corner: link.corner, hoverChip: link.hoverChip,
                  accessibilityLabel: link.accessibilityLabel,
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
        let commands = commands()
        let activate: () -> Void = { if let terminal { controller.choose(.terminal(terminal.id)) } }
        SelectableRow(id: row.id, selected: selected, activate: activate) {
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
            .backgroundCard(row.background, source: .terminal(row.id), activate: activate, commands: commands)
        }
        .accessibilityLabel(row.name)
        .accessibilityValue(BackgroundCard(jobs: row.background).accessibilityValue(status: row.status))
        .modifier(RowCommandActions(groups: commands))
        .modifier(RowCommandContextMenu(groups: commands))
    }

    func commands() -> [[RowCommand]] {
        guard terminal != nil else { return [] }
        let enabled = controller.canChangeWorkspace
        return [
            [RowCommand(title: "Rename…", enabled: enabled) {
                if let current = controller.state.terminal(id: row.id) { controller.sheets.presentRename(terminal: current) }
            }],
            RowCommand.open(path: project.path),
            [RowCommand(title: "Remove Terminal", role: .destructive, enabled: enabled) {
                if let current = controller.state.terminal(id: row.id) { controller.terminals.close(terminal: current) }
            }]
        ]
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

/// `TaskRowMark` drawn: a ring for a state that can still move (`StatusMark`), a disc for one that holds
/// (`SettledMark`): the green check once the Operator's work on the task ended, the pause disc while paused. A
/// selected row is neutral, so every mark keeps its colours. Decorative: the row's value reads the line.
struct TaskRowMarkView: View {
    let mark: TaskRowMark
    let size: CGFloat

    var body: some View {
        switch mark {
        case .status(let status): StatusMark(status: status, size: size)
        case .ended: SettledMark(.finished, size: size)
        case .pauseSign: SettledMark(.paused, size: size)
        }
    }
}
