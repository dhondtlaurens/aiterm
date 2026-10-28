import SwiftUI
import AiTermUI
import AiTermCore

/// The broadcast's header under the OPERATOR heading (decided 21 Oct 2026), a project header's anatomy
/// (`ProjectHeaderRow`): the chevron, the broadcast's glyph where a project has its host's, its name, and its
/// progress after it, `2 of 6`, `paused · 2 of 6` while paused, in `Typography.monoChip` and the surface's
/// secondary ink; then the board button in the "+"'s slot. Folded, it shows what needs you in its group, once,
/// as an amber `StatusCountChips` count, whose click opens the group at the first row that needs you.
///
/// Its click and ↩ fold the group, as a project header's do; the board opens from its button and from Open
/// Board in its menu, which also has Rename…, Pause Broadcast or Resume Broadcast, and End Broadcast…. Its
/// tooltip is its projects and its whole status line, as the board's band says it. Selected, it shows no window.
struct BroadcastHeaderRow: View {
    /// The group, its header and what it hides: an equatable value, so a change to the run it draws nothing
    /// of (a decision recorded, a token) does not re-run this body.
    let section: BroadcastSection
    let controller: AppController
    @Environment(\.interfaceScale) private var scale
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    /// The broadcast's glyph: the header's mark, and a project header's badge counting the tasks it holds.
    static let glyph = "dot.radiowaves.left.and.right"

    private var row: BroadcastRow { section.header }

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(row.id)
        #endif
        let selected = controller.focus.isSelected(row.id)
        let folds = controller.canChangeWorkspace
        HStack(spacing: scale(Space.base)) {
            // Only the label folds the group; the chip and the board button keep their own clicks.
            HStack(spacing: scale(Space.base)) {
                HeaderChevron(collapsed: section.folded).frame(width: SidebarRowLayout.chevronWidth(scale))
                ProviderIcon(.symbol(Self.glyph))
                HStack(spacing: scale(Space.gap)) {
                    HeaderTitle(text: row.title)
                    if let progress = row.headerProgress { HeaderProgress(text: progress) }
                }
                Spacer(minLength: scale(Space.tight))
                // Folded only: open, the rows under it say all of this.
                if section.folded, !section.attention.isEmpty {
                    Button { controller.openAttention(of: row.id) } label: { StatusCountChips(counts: section.attention) }
                        .buttonStyle(.plain)
                }
            }
            .contentShape(Rectangle())
            // A locked workspace folds nothing: `.subviews` keeps the chip's click, which only opens and selects.
            .gesture(TapGesture().onEnded { controller.toggleFolded(run: row.id) }, including: folds ? .all : .subviews)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Self.label(row))
            .accessibilityValue(Self.spoken(section))
            .accessibilityAddTraits(folds ? .isButton : [])
            .accessibilityAddTraits(selected ? .isSelected : [])
            .modifier(FoldAction(enabled: folds) { controller.toggleFolded(run: row.id) })
            // Open Board, then the menu's other items, as named actions.
            .accessibilityActions {
                ForEach(Self.voiceOverActions(row, canChangeWorkspace: controller.canChangeWorkspace), id: \.self) { item in
                    Button(item.actionTitle) { controller.perform(item, onBroadcast: row.id) }
                }
            }
            BoardButton { controller.openBoard(row.id) }
        }
        .frame(height: scale(Size.projectRow)).padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .modifier(RowPill(selected: selected))
        .help(Self.help(row))
        .contextMenu {
            OperatorMenuButtons(items: OperatorMenus.broadcast(row), enabled: { Self.enabled($0, canChangeWorkspace: controller.canChangeWorkspace) }) {
                controller.perform($0, onBroadcast: row.id)
            }
        }
    }

    /// Whether a menu item can be chosen: Open Board changes nothing, so a locked workspace greys only the rest.
    static func enabled(_ item: OperatorMenuItem, canChangeWorkspace: Bool) -> Bool {
        item == .openBoard || canChangeWorkspace
    }

    /// What VoiceOver offers beside the fold: the menu's items it can choose now, Open Board first. An action
    /// cannot be greyed, only left out.
    static func voiceOverActions(_ row: BroadcastRow, canChangeWorkspace: Bool) -> [OperatorMenuItem] {
        OperatorMenus.broadcast(row).filter { $0 != .separator && enabled($0, canChangeWorkspace: canChangeWorkspace) }
    }

    /// What VoiceOver calls the header.
    static func label(_ row: BroadcastRow) -> String { "Broadcast \(row.title)" }

    /// The header as VoiceOver reads it: the progress, every project, the whole status line, and what needs you
    /// while it is folded.
    static func spoken(_ section: BroadcastSection) -> String {
        let row = section.header
        let attention = section.folded && !section.attention.isEmpty ? SidebarModel.statusCountsLabel(section.attention) : nil
        return [row.headerProgress, row.projectsHelp.isEmpty ? nil : row.projectsHelp, row.line.tooltip, attention]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// The tooltip: its projects, then its whole status line.
    static func help(_ row: BroadcastRow) -> String {
        [row.projectsHelp, row.line.tooltip].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// The header's progress, in `Typography.monoChip` and its surface's secondary ink: it keeps its width, and the
/// name is what truncates.
private struct HeaderProgress: View {
    let text: String
    @Environment(\.surface) private var surface

    var body: some View {
        Text(verbatim: text).font(Typography.monoChip).foregroundStyle(surface.secondaryInk).lineLimit(1).fixedSize()
    }
}

/// The board button, in the trailing slot where a project header has its "+": the board's glyph,
/// `rectangle.split.3x1`, drawn as the "+" is, in the surface's secondary ink.
private struct BoardButton: View {
    let open: () -> Void
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    var body: some View {
        Button(action: open) {
            Image(systemName: "rectangle.split.3x1").font(Typography.label).foregroundStyle(surface.secondaryInk)
                .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(OperatorMenuItem.openBoard.title)
        .accessibilityLabel(OperatorMenuItem.openBoard.title)
    }
}

/// The fold as the header's default VoiceOver action, there only while the workspace can change.
private struct FoldAction: ViewModifier {
    let enabled: Bool
    let fold: () -> Void

    func body(content: Content) -> some View {
        if enabled { content.accessibilityAction(.default, fold) } else { content }
    }
}

/// The Operator's own row, first in the broadcast's group (decided 21 Oct 2026): a full task row
/// (`SelectableRow`) washed at rest (`Palette.operatorRow`), Claude's `VendorMark` as its avatar, the title
/// `Operator`, then its own session's line, `OperatorBadge(line:)`, and the shared task mark trailing,
/// a completed check once the broadcast succeeds. No project,
/// ticket or branch line: the board has all of that. ↑ ↓ peek at its window, as on a task; a click or ↩ brings
/// it to front with iTerm2, or reopens it in front when it is closed (`RowFocus.select(.operation)`).
struct OperatorRowView: View {
    let row: OperatorRow
    let controller: AppController
    @Environment(\.interfaceScale) private var scale
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    /// What VoiceOver calls the row.
    static let label = "Operator, Claude Code session"

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(row.id)
        #endif
        let selected = controller.focus.isSelected(row.id)
        SelectableRow(selected: selected, washed: true, activate: { controller.focus.select(.operation(row.runId)) }) {
            HStack(spacing: scale(Space.inset)) {
                AvatarGroupView(group: AvatarGroup(marks: [row.agent], overflow: 0))
                VStack(alignment: .leading, spacing: scale(Space.tight)) {
                    RowTitle(OperatorRow.title)
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
        .accessibilityLabel(Self.label)
        .accessibilityValue(row.line.tooltip)
        .accessibilityHint(Text("Press Return to bring its window to front."))
    }
}
