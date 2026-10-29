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
    /// An end picked from a running card's end line (`OperatorController.changeEnd`).
    var changeEnd: @MainActor (_ task: UUID, _ end: TaskEnd) -> Void = { _, _ in }
    /// One More Round or Accept As It Is, on a card out of fix rounds (`OperatorController.answerFixRounds`).
    var answerFixRounds: @MainActor (_ task: UUID, _ answer: BroadcastBoard.FixRoundsAnswer) -> Void = { _, _ in }
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
/// `SheetLayout`'s anatomy: the title; a band line, the broadcast's `BroadcastStatusLine` as its row says it; then a
/// line each for Asked, the Goal and Each task, `Space.base` apart, each cut at its end with the whole of it in its
/// tooltip; then, `Space.block` under them, the tab bar, Settings' `SegmentedControl` in its accent style at
/// `Size.control`, Board · Activity · Summary, picked by click or ⌘1–⌘3 (the broadcast's sheet, 1A, 29 Oct 2026). It
/// opens on `BroadcastBoard.firstTab` and stays where you put it; Summary is dimmed until the broadcast reached it.
/// Board is the columns, each `Sheet.boardColumn` wide, and the board scrolls as one, down and sideways, between the
/// rules and from edge to edge (2B); once every task is done they all sit in Done. A card's click closes the sheet
/// first, then opens what resolves it (`choose`). Activity is the run's log (`BroadcastActivityView`), Summary the
/// Operator's summary and what it left for you (`BroadcastSummaryView`); both scroll down. The footer is the same on
/// every tab. Equatable by what it draws, its actions left out (they act on the broadcast as it is when
/// pressed), so the host's `.equatable()` skips a body that would draw the same; the feed redraws Activity alone.
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
        SheetLayout(title: board.title, height: Sheet.height, bandHeight: nil,
                    scrolls: shown == .board ? [.horizontal, .vertical] : .vertical, contentVerticalPadding: Space.block) {
            VStack(alignment: .leading, spacing: Space.block) {
                VStack(alignment: .leading, spacing: Space.base) {
                    BroadcastStatusLine(line: board.band, progress: board.progress)
                    ForEach(board.headerLines, id: \.label) { Self.headerLine($0) }
                }
                tabBar.frame(height: Size.control)
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
            case .summary: BroadcastSummaryView(board: board)
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

    /// The columns, `Space.gap` apart, from the content's leading margin to its trailing one: the sheet's scroll
    /// carries them sideways and down.
    private var columns: some View {
        HStack(alignment: .top, spacing: Space.gap) {
            ForEach(board.columns) { lane in column(lane).frame(width: Sheet.boardColumn) }
        }
    }

    private func choose(_ opens: BroadcastBoard.Opens) {
        Self.choose(opens, dismiss: { dismiss.afterThisEvent() }, actions: actions)
    }

    /// A heading over its cards, `Space.gap` apart.
    private func column(_ lane: BroadcastBoard.Lane) -> some View {
        VStack(alignment: .leading, spacing: Space.base) {
            BoardHeading(title: lane.title, count: lane.cards.count)
            VStack(alignment: .leading, spacing: Space.gap) {
                if lane.cards.isEmpty {
                    // At the card's own inset, so it reads on the line of the cards' titles beside it.
                    Text(lane.empty).font(Typography.help).foregroundStyle(Palette.muted).padding(.vertical, Space.block)
                }
                ForEach(lane.cards) { card in BoardCardView(card: card, choose: choose, actions: actions).equatable() }
            }
        }
    }

    /// A header line: its label in `Palette.text` at medium weight, the rest muted, in `Typography.help`, one line cut
    /// at its end, the whole of it in its tooltip.
    private static func headerLine(_ clause: BroadcastBoard.Clause) -> some View {
        Text("\(Text(verbatim: clause.label).fontWeight(.medium).foregroundStyle(Palette.text)) \(clause.text)")
            .font(Typography.help).foregroundStyle(Palette.muted)
            .lineLimit(1).truncationMode(.tail).help(clause.whole)
            .frame(maxWidth: .infinity, alignment: .leading)
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

/// A task on the board (spec §4, §13): a `groupChrome` box, `Space.block` inside, its lines `Space.base` apart (the
/// broadcast's sheet, 3B, 29 Oct 2026). Its agent's
/// `VendorMark` on every card, started or not (spec §15.4), and beside it, on the title's leading edge as
/// on a task row, the title, two lines at most; then the quiet Jira and merge-request `Badge`s a task row
/// wears, and the project when the broadcast spans several, never the branch; then its status line, one
/// `Size.chip` line: the task's `OperatorBadge`, or `taken over` with no badge. A card
/// that needs you has its edge in `Palette.statusChipAttentionStroke` and the needs-you badge, nothing more:
/// the card is the action. Its tooltip is the model the Operator chose and why. A task with several worker
/// tabs lists them under a `Hairline` (`BoardTabLine`), each its own button, the card's click above them.
///
/// On a broadcast set up with the Task step (14A, 17A), the first worker's model and reasoning sit on a line of their
/// own under the badges, in `Typography.monoCode` and `Palette.muted`, never cut short (a card with several tabs puts
/// each under its tab's key instead); and while the task runs, `ends at` and its end as a `Badge` on the line under
/// that, whose menu picks another, Merge and Local merge disabled while the Merge slice is off. The badge takes its own
/// click. A task out of its fix rounds (16) has, under the card's rule, a `Hairline` as over the tabs, the last
/// verdict's counts in a `HelpText` when one was recorded, then One More Round and Accept As It Is as links, `Space.gap`
/// apart and `Space.base` under it; once you answered, what you answered in their place, until the question is
/// resolved. A worktree the closing kept says why there, in a `HelpText`, once the closing recorded it. Equatable by
/// its card alone, so a change to another card redraws this one not at all.
struct BoardCardView: View, Equatable {
    let card: BroadcastBoard.Card
    /// What the card's click, or a tab line's, opens: the sheet closes first (`BroadcastBoardSheet.choose`).
    let choose: (BroadcastBoard.Opens) -> Void
    /// What its end line and its fix rounds' links do.
    let actions: BoardActions
    @State private var hovered = false
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.card == rhs.card }

    init(card: BroadcastBoard.Card, choose: @escaping (BroadcastBoard.Opens) -> Void, actions: BoardActions) {
        self.card = card; self.choose = choose; self.actions = actions
    }

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
            if hasFoot { foot }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupChrome(fill: hovered ? Palette.rowHoverSolid : Palette.surface,
                     edge: card.needsYou ? Palette.statusChipAttentionStroke : Palette.border)
        .help(card.modelTooltip ?? "")
    }

    /// The card's own part, its click's: the mark and the lines, `Space.block` inside, the tabs' hairline included.
    private var head: some View {
        HStack(alignment: .top, spacing: Space.base) {
            if let agent = card.agent { VendorMark(agent: agent.session, size: Size.avatar) }
            lines
        }
        .padding(Space.block)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The worker tabs under a `Hairline`, `Space.gap` apart.
    private var tabs: some View {
        VStack(alignment: .leading, spacing: Space.gap) {
            ForEach(card.tabs) { tab in BoardTabLine(tab: tab, choose: { choose(tab.opens) }) }
        }
        .ruled()
    }

    private var hasFoot: Bool { card.fixRounds != nil || card.notice != nil }

    /// What a card says under its rule: why its worktree was kept, or a task out of its fix rounds' counts and its
    /// answers, or what you answered.
    private var foot: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            if let notice = card.notice { HelpText(notice) }
            if let fixRounds = card.fixRounds {
                if let counts = fixRounds.counts { HelpText(counts) }
                if let answered = fixRounds.answered {
                    HelpText(Self.answered(answered))
                } else {
                    HStack(spacing: Space.gap) {
                        ForEach(BroadcastBoard.FixRoundsAnswer.allCases, id: \.self) { answer in
                            Button(answer.title) { actions.answerFixRounds(card.id, answer) }.buttonStyle(.link).font(Typography.help)
                        }
                    }
                }
            }
        }
        .ruled()
    }

    /// What the card says once you answered its fix rounds: `You answered: one more round.`
    static func answered(_ answer: BroadcastBoard.FixRoundsAnswer) -> String { "You answered: \(answer.words)." }

    private var lines: some View {
        VStack(alignment: .leading, spacing: Space.base) {
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
            if let combination = card.combination {
                Text(verbatim: combination).font(Typography.monoCode).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let end = card.end { BoardEndLine(title: card.title, end: end) { actions.changeEnd(card.id, $0) } }
            if card.takenOver {
                Text("taken over").font(Typography.mono).foregroundStyle(Palette.muted).frame(height: Size.chip)
            } else if let line = card.line {
                OperatorBadge(line: line)
            }
            if let refusal = card.mergeRefusal {
                HelpText("merge refused by the Oracle").help(refusal)
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

private extension View {
    /// A card's part under its rule: a `Hairline`, `Space.block` clear of it, of the card's edges and of what is
    /// above it.
    func ruled() -> some View {
        padding(.top, Space.block)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Hairline() }
            .padding([.horizontal, .bottom], Space.block)
    }
}

/// A running card's end line (17A), a `Size.chip` line: `ends at` in `Typography.monoCode` and `Palette.muted`, then
/// `Space.base` on its end as a `Badge` whose menu, headed `Cart drawer ends at`, lists the four ends, the current one
/// ticked and those the Merge slice keeps out disabled. No test clicks the badge: AppKit's menu tracking blocks inside
/// `sendEvent` until the menu closes.
struct BoardEndLine: View {
    let title: String
    let end: BroadcastBoard.EndLine
    let pick: (TaskEnd) -> Void

    var body: some View {
        HStack(spacing: Space.base) {
            Text("ends at").font(Typography.monoCode).foregroundStyle(Palette.muted)
            Badge(end.current.displayName, accessibilityLabel: "Ends at \(end.current.displayName)") {
                Section("\(title) ends at") {
                    ForEach(TaskEnd.allCases, id: \.self) { item in
                        Toggle(item.title, isOn: Binding(get: { item == end.current }, set: { if $0 { pick(item) } }))
                            .disabled(!end.selectable.contains(item))
                    }
                }
            }
            .fixedSize()
        }
        .frame(height: Size.chip)
    }
}

/// One worker tab on a card (P5 A), a `Size.chip` line: the tab's agent's `VendorMark` at `Size.inlineMark`,
/// centred under the card's `Size.avatar` mark; its key in `Typography.monoChip` and `Palette.text` on the
/// title's leading edge; its state `Space.base` after it, an `OperatorBadge` (needs you in the attention chip);
/// its `StatusMark` at `Size.statusMarkSmall` trailing; under it, on a broadcast set up with the Agents step, the tab's
/// model and reasoning on a `Size.chip` line of their own on the key's edge, in `Typography.monoCode` and `Palette.muted`.
/// Hovered, `Palette.badgeHovered` at `Radius.chip`, `Space.tight` beyond the line. Its click closes the board and
/// brings the tab forward; a closed tab is muted, with no mark, and is no button.
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
        VStack(alignment: .leading, spacing: 0) {
            if BroadcastBoardSheet.isButton(tab.opens) {
                Button(action: choose) { line }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 }
                    .accessibilityHint(Text(BoardCardView.hint(tab.opens)))
            } else {
                line
            }
            if let combination = tab.combination {
                Text(verbatim: combination).font(Typography.monoCode).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Size.avatar + Space.base).frame(minHeight: Size.chip)
            }
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
