import SwiftUI
import AiTermUI
import AiTermCore

/// What the board's cards and buttons do, handed in by `AppController.boardActions(for:dismiss:)`; a
/// snapshot or a test hands in none.
struct BoardActions {
    /// A card's or a worker tab line's click, the sheet already closed (`BroadcastBoardSheet.choose`).
    var open: @MainActor (BroadcastBoard.Opens) -> Void = { _ in }
    var pause: @MainActor () -> Void = {}
    var resume: @MainActor () -> Void = {}
    /// `confirming`: End Broadcast… asks first; End Broadcast from a complete broadcast does not.
    var end: @MainActor (_ confirming: Bool) -> Void = { _ in }
    var startFresh: @MainActor () -> Void = {}
}

/// The board's footer at each moment (spec §9, §13): Pause Broadcast or Resume Broadcast and End
/// Broadcast… while it runs; End Broadcast on ⌘↩ once it is complete, asking nothing; and when the
/// Operator's window could not be reopened, a Notice saying so with Start Fresh on ⌘↩. A complete
/// broadcast outranks a failed reopening: it keeps End Broadcast on ⌘↩, the Notice still shown and Start Fresh a
/// plain button beside it. A shelved board, read from the Shelf, has Close alone. Close (⎋) always.
struct BoardFooter: Equatable {
    enum Button: Hashable {
        case pause, resume, endConfirm, end, startFresh

        var title: String {
            switch self {
            case .pause: "Pause Broadcast"
            case .resume: "Resume Broadcast"
            case .endConfirm: "End Broadcast…"
            case .end: "End Broadcast"
            case .startFresh: "Start Fresh"
            }
        }

        @MainActor func perform(_ actions: BoardActions) {
            switch self {
            case .pause: actions.pause()
            case .resume: actions.resume()
            case .endConfirm: actions.end(true)
            case .end: actions.end(false)
            case .startFresh: actions.startFresh()
            }
        }
    }

    /// The footer's Notice: its title, and its description under it.
    struct NoticeText: Equatable { var title: String; var description: String }

    let secondary = "Close"
    var leading: [Button]
    var primary: Button?
    var notice: NoticeText?

    init(_ board: BroadcastBoard, reopenFailed: Bool) {
        notice = reopenFailed && !board.isShelved
            ? NoticeText(title: "Couldn’t reopen the Operator’s window",
                         description: "Its conversation couldn’t be resumed. A fresh one starts from the board and what it decided so far.")
            : nil
        if board.isShelved {
            leading = []; primary = nil
        } else if board.isComplete {
            leading = reopenFailed ? [.startFresh] : []; primary = .end
        } else if reopenFailed {
            // End Broadcast… stays in the row's menu.
            leading = []; primary = .startFresh
        } else {
            leading = [board.isPaused ? .resume : .pause, .endConfirm]; primary = nil
        }
    }
}

/// The broadcast's sheet (spec §4, §13; the Operator sheet, 21 Oct 2026), `Sheet.width` by `Sheet.height` in
/// `SheetLayout`'s anatomy: the title; a band line, the broadcast's `BroadcastStatusLine` as its row says it; the
/// Asked line, two lines at most, the whole of it in its tooltip; then the tab bar, Settings' `SegmentedControl` in
/// its accent style, Board · Activity · Summary, picked by click or ⌘1–⌘3. It opens on `BroadcastBoard.firstTab`
/// and stays where you put it; Summary is dimmed until the broadcast reached it. Board is the columns, each
/// `Sheet.boardColumn` wide and scrolling on its own, the row of them scrolling sideways; once every task is done
/// they all sit in Done. A card's click closes the sheet first, then opens what resolves it (`choose`). Activity
/// is the run's log (`BroadcastActivityView`), Summary the Operator's summary and what it left for you
/// (`BroadcastSummaryView`); both scroll as one. The footer is the same on every tab. Equatable by what it draws,
/// its actions left out (they act on the broadcast as it is when pressed), so the host's `.equatable()` skips a
/// body that would draw the same; the feed redraws Activity alone.
struct BroadcastBoardSheet: View, Equatable {
    let board: BroadcastBoard
    let reopenFailed: Bool
    let actions: BoardActions
    /// The run's activity log as the host follows it; nil where Activity is handed its `entries` instead.
    let activity: ActivityFeed?
    /// What Activity lists without a feed, and the row it opens with: the snapshots' (`seeded(tab:entries:open:)`).
    private(set) var entries: [ActivityEntry] = []
    private(set) var openEntry: UUID?
    private var _tab: State<BroadcastBoard.Tab>
    private var tab: BroadcastBoard.Tab { get { _tab.wrappedValue } nonmutating set { _tab.wrappedValue = newValue } }
    @Environment(\.dismiss) private var dismiss
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.board == rhs.board && lhs.reopenFailed == rhs.reopenFailed && lhs.activity === rhs.activity && lhs.entries == rhs.entries
            && lhs.openEntry == rhs.openEntry
    }

    init(board: BroadcastBoard, reopenFailed: Bool, actions: BoardActions, activity: ActivityFeed?) {
        self.board = board; self.reopenFailed = reopenFailed; self.actions = actions; self.activity = activity
        _tab = State(initialValue: board.firstTab)
    }

    /// A card's click: the sheet closes, then what the card opens comes forward. A Todo card has nothing to
    /// open and is no button, so nothing happens.
    @MainActor static func choose(_ opens: BroadcastBoard.Opens, dismiss: () -> Void, actions: BoardActions) {
        guard isButton(opens) else { return }
        dismiss()
        actions.open(opens)
    }

    /// Whether a card that opens this is a button.
    static func isButton(_ opens: BroadcastBoard.Opens) -> Bool { opens != .nothing }

    /// The tab the sheet shows when it is on `tab`: the Board instead of a tab the broadcast has gone back from, as a
    /// Summary when a new plan makes a complete run active again.
    static func shownTab(_ tab: BroadcastBoard.Tab, on board: BroadcastBoard) -> BroadcastBoard.Tab {
        board.isSelectable(tab) ? tab : .board
    }

    /// ⌘1–⌘3 pick the tabs in the order the tab bar draws them.
    static func key(of tab: BroadcastBoard.Tab) -> KeyEquivalent {
        KeyEquivalent(Character(String(BroadcastBoard.Tab.allCases.firstIndex(of: tab)! + 1)))
    }

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(board.runId)
        #endif
        let footer = BoardFooter(board, reopenFailed: reopenFailed)
        let shown = Self.shownTab(tab, on: board)
        SheetLayout(title: board.title, height: Sheet.height, width: Sheet.width, bandHeight: nil, scrolls: shown != .board,
                    contentVerticalPadding: Space.block) {
            VStack(alignment: .leading, spacing: Space.base) {
                BroadcastStatusLine(line: board.band, progress: board.progress)
                Self.asked(board.clauses).font(Typography.help).foregroundStyle(Palette.muted)
                    .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true).help(board.asked)
                    .frame(maxWidth: .infinity, alignment: .leading)
                tabBar
            }
        } content: {
            switch shown {
            case .board: columns
            case .activity:
                if let activity {
                    ActivityFeedView(feed: activity, titles: titles)
                } else {
                    BroadcastActivityView(entries: entries, titles: titles, openId: openEntry)
                }
            case .summary: BroadcastSummaryView(summary: board.summary, leftForYou: board.leftForYou)
            }
        } footer: {
            SheetFooter(secondary: footer.secondary, primary: footer.primary?.title, cancel: { dismiss.afterThisEvent() },
                        submit: { footer.primary?.perform(actions) }) {
                HStack(spacing: Space.base) {
                    if let notice = footer.notice { Notice(title: notice.title, description: notice.description) }
                    ForEach(footer.leading, id: \.self) { button in Button(button.title) { button.perform(actions) } }
                }
            }
        }
        // ⌘1–⌘3, on hidden buttons, as Settings' ⌘1–⌘4: the tab bar's segments are not buttons of their own.
        .background {
            ForEach(BroadcastBoard.Tab.allCases, id: \.self) { item in
                Button(item.title) { select(item) }.keyboardShortcut(Self.key(of: item), modifiers: .command)
            }
            .hidden()
        }
    }

    /// Settings' tab bar: the same `SegmentedControl` in its accent style, labels in `Typography.body` that the
    /// control inks, Summary dimmed and disabled until there is one to read.
    private var tabBar: some View {
        SegmentedControl(values: BroadcastBoard.Tab.allCases, selection: Binding(get: { Self.shownTab(tab, on: board) }, set: { select($0) }),
                         style: .accent, isSelectable: board.isSelectable) { item, _ in
            Text(item.title).font(Typography.body)
        }
    }

    private func select(_ item: BroadcastBoard.Tab) {
        guard board.isSelectable(item) else { return }
        tab = item
    }

    /// The board's tasks' titles by id, for Activity's lines.
    private var titles: [UUID: String] {
        Dictionary(board.columns.flatMap(\.cards).map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    /// The columns, `Space.gap` apart, the first on the content's leading margin; the row of them runs past the
    /// trailing margin to the sheet's edge and scrolls sideways, the last ending on the margin.
    private var columns: some View {
        BoardScroll(.horizontal) {
            HStack(alignment: .top, spacing: Space.gap) {
                ForEach(board.columns) { lane in column(lane).frame(width: Sheet.boardColumn) }
            }
            .padding(.trailing, Space.margin)
        }
        .padding(.trailing, -Space.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func choose(_ opens: BroadcastBoard.Opens) {
        Self.choose(opens, dismiss: { dismiss.afterThisEvent() }, actions: actions)
    }

    private func column(_ lane: BroadcastBoard.Lane) -> some View {
        VStack(alignment: .leading, spacing: Space.base) {
            BoardHeading(title: lane.title, count: lane.cards.count)
            BoardScroll {
                VStack(alignment: .leading, spacing: Space.base) {
                    if lane.cards.isEmpty {
                        // At the card's own inset, so it reads on the line of the cards' titles beside it.
                        Text(lane.empty).font(Typography.help).foregroundStyle(Palette.muted).padding(.vertical, Space.inset)
                    }
                    ForEach(lane.cards) { card in BoardCardView(card: card, choose: choose).equatable() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// `Asked …  · Review …  · Done …`, each label in `Palette.text` at medium weight, the rest muted.
    static func asked(_ clauses: [BroadcastBoard.Clause]) -> Text {
        clauses.enumerated().reduce(Text(verbatim: "")) { text, item in
            let label = Text(verbatim: item.element.label).fontWeight(.medium).foregroundStyle(Palette.text)
            let lead = item.offset == 0 ? "" : " · "
            return Text("\(text)\(lead)\(label) \(item.element.text)")
        }
    }
}

#if DEBUG
extension BroadcastBoardSheet {
    /// The sheet already on `tab`, Activity listing `entries` with `open` open: what only clicks and a run folder
    /// reach in the app, for the snapshots.
    func seeded(tab: BroadcastBoard.Tab, entries: [ActivityEntry] = [], open: UUID? = nil) -> Self {
        var sheet = self
        sheet._tab = State(initialValue: tab)
        sheet.entries = entries
        sheet.openEntry = open
        return sheet
    }
}
#endif

/// Activity as the run's feed has it: this view alone reads the feed, so an append redraws the list and not
/// the sheet around it.
private struct ActivityFeedView: View {
    let feed: ActivityFeed
    let titles: [UUID: String]

    var body: some View { BroadcastActivityView(entries: feed.entries, titles: titles) }
}

/// A column's head: a `SidebarHeading` and its count in `Typography.monoChip`,
/// `Size.menuRow` tall.
struct BoardHeading: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: Space.snug) {
            SidebarHeading(title)
            Text(verbatim: "\(count)").font(Typography.monoChip).foregroundStyle(Palette.muted)
        }
        .frame(height: Size.menuRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count)")
    }
}

/// The board's own scrolls: a column's, vertical, and the row of columns', sideways. A `ScrollView`, or in the
/// snapshots — whose `ImageRenderer` cannot materialise one — its content clipped at the top and leading edge,
/// a sideways row laid out whole first, so what lies past the edge is cut rather than squeezed.
struct BoardScroll<Content: View>: View {
    let axis: Axis
    let content: Content
    #if DEBUG
    @Environment(\.snapshotRendering) private var isSnapshot
    #else
    private let isSnapshot = false
    #endif

    init(_ axis: Axis = .vertical, @ViewBuilder content: () -> Content) {
        self.axis = axis; self.content = content()
    }

    var body: some View {
        switch (axis, isSnapshot) {
        case (.vertical, true):
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        case (.horizontal, true):
            // `minWidth: 0`: a frame with no minimum is at least as wide as the row it holds, and would widen the sheet.
            content.fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        case (.vertical, false):
            ScrollView { content.frame(maxWidth: .infinity, alignment: .topLeading) }.scrollIndicators(.automatic)
        case (.horizontal, false):
            ScrollView(.horizontal) { content.frame(maxHeight: .infinity, alignment: .topLeading) }.scrollIndicators(.automatic)
        }
    }
}

/// A task on the board (spec §4, §13): a `groupChrome` box, `Space.inset` inside. Its agent's
/// `VendorMark` on every card, started or not (spec §15.4), and beside it, on the title's leading edge as
/// on a task row, the title, two lines at most; then the quiet Jira and merge-request `Badge`s a task row
/// wears, and the project when the broadcast spans several, never the branch; then its status line, one
/// `Size.chip` line: the task's `OperatorBadge`, or `taken over` with no badge. A card
/// that needs you has its edge in `Palette.statusChipAttentionStroke` and the needs-you badge, nothing more:
/// the card is the action. Its tooltip is the model the Operator chose and why. A task with several worker
/// tabs lists them under a `Hairline` (`BoardTabLine`), each its own button, the card's click above them.
/// Equatable by its card alone, so a change to another card redraws this one not at all.
struct BoardCardView: View, Equatable {
    let card: BroadcastBoard.Card
    /// What the card's click, or a tab line's, opens: the sheet closes first (`BroadcastBoardSheet.choose`).
    let choose: (BroadcastBoard.Opens) -> Void
    @State private var hovered = false
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.card == rhs.card }

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(card.id)
        #endif
        VStack(alignment: .leading, spacing: 0) {
            if BroadcastBoardSheet.isButton(card.opens) {
                Button { choose(card.opens) } label: { head }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 }
                    .accessibilityHint(Text(Self.hint(card.opens)))
            } else {
                head
            }
            if !card.tabs.isEmpty { tabs }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupChrome(fill: hovered ? Palette.rowHoverSolid : Palette.surface,
                     edge: card.needsYou ? Palette.statusChipAttentionStroke : Palette.border)
        .help(card.modelTooltip ?? "")
    }

    /// The card's own part, its click's: the mark and the lines, `Space.inset` inside, `Space.base` above the
    /// tabs' hairline when it has them.
    private var head: some View {
        HStack(alignment: .top, spacing: Space.base) {
            if let agent = card.agent { VendorMark(agent: agent.session, size: Size.avatar) }
            lines
        }
        .padding([.horizontal, .top], Space.inset)
        .padding(.bottom, card.tabs.isEmpty ? Space.inset : Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The worker tabs under a `Hairline`, `Space.base` below it, `Space.tight` apart.
    private var tabs: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            ForEach(card.tabs) { tab in BoardTabLine(tab: tab, choose: { choose(tab.opens) }) }
        }
        .padding(.top, Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
        .padding([.horizontal, .bottom], Space.inset)
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(card.title).font(Typography.body).foregroundStyle(Palette.text)
                .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            if card.ticket != nil || card.mr != nil || card.project != nil {
                HStack(spacing: Space.gap) {
                    TaskBadges(ticket: card.ticket, ticketSummary: card.ticketSummary, mr: card.mr, mrHost: card.mrHost, mrTitle: card.mrTitle)
                    if let project = card.project {
                        Text(project).font(Typography.mono).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.tail)
                    }
                }
                .frame(height: Size.chip)
            }
            if card.takenOver {
                Text("taken over").font(Typography.mono).foregroundStyle(Palette.muted).frame(height: Size.chip)
            } else if let line = card.line {
                OperatorBadge(line: line)
            }
        }
    }

    /// What VoiceOver says a card's click does.
    static func hint(_ opens: BroadcastBoard.Opens) -> String {
        switch opens {
        case .taskWindow: "Opens the task’s window."
        case .tab: "Brings this tab to the front."
        case .operatorWindow: "Opens the Operator’s window."
        case .sidebarBanner: "Shows the problem in the sidebar’s banner."
        case .nothing: ""
        }
    }
}

/// One worker tab on a card (P5 A), a `Size.chip` line: the tab's agent's `VendorMark` at `Size.inlineMark`,
/// centred under the card's `Size.avatar` mark; its key in `Typography.monoChip` and `Palette.text` on the
/// title's leading edge; its state `Space.base` after it, an `OperatorBadge` (needs you in the attention chip);
/// its `StatusMark` at `Size.statusMarkSmall` trailing. Hovered, `Palette.badgeHovered` at `Radius.chip`,
/// `Space.tight` beyond the line. Its click closes the board and brings the tab forward; a closed tab is muted,
/// with no mark, and is no button.
struct BoardTabLine: View {
    let tab: BroadcastBoard.TabLine
    let choose: () -> Void
    private var _hovered = State(initialValue: false)
    private var hovered: Bool {
        get { _hovered.wrappedValue }
        nonmutating set { _hovered.wrappedValue = newValue }
    }

    init(tab: BroadcastBoard.TabLine, choose: @escaping () -> Void) {
        self.tab = tab; self.choose = choose
    }

    var body: some View {
        if BroadcastBoardSheet.isButton(tab.opens) {
            Button(action: choose) { line }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .accessibilityHint(Text(BoardCardView.hint(tab.opens)))
        } else {
            line
        }
    }

    private var line: some View {
        HStack(spacing: 0) {
            VendorMark(agent: tab.agent.session, size: Size.inlineMark).frame(width: Size.avatar)
            Text(verbatim: tab.key).font(Typography.monoChip).foregroundStyle(tab.isClosed ? Palette.muted : Palette.text)
                .lineLimit(1).fixedSize().padding(.leading, Space.base)
            OperatorBadge(line: tab.line).padding(.leading, Space.base)
            Spacer(minLength: Space.tight)
            if let status = tab.status { StatusMark(status: status, size: Size.statusMarkSmall) }
        }
        .frame(height: Size.chip)
        .background {
            if hovered { RoundedRectangle(cornerRadius: Radius.chip).fill(Palette.badgeHovered).padding(-Space.tight) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tab.key), \(tab.line.tooltip)")
    }
}

/// A task's quiet Jira and merge-request `Badge`s, as a task row wears them.
struct TaskBadges: View {
    let ticket: String?
    let ticketSummary: String?
    let mr: String?
    let mrHost: CodeHost?
    let mrTitle: String?

    var body: some View {
        if let ticket { Badge(ticket, icon: .brand(Palette.jira), help: ticketSummary, style: .quiet).fixedSize() }
        if let mr { Badge(mr, icon: .brand((mrHost ?? .gitLab).brand), help: mrTitle, style: .quiet).fixedSize() }
    }
}
