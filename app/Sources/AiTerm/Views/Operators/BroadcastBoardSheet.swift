import SwiftUI
import AiTermUI
import AiTermCore

/// What the sheet's rows and buttons do, handed in by `AppController.boardActions(for:dismiss:)`; a
/// snapshot or a test hands in none.
struct BoardActions {
    /// A row's click, or a question's button that opens where it waits, the sheet already closed (`BroadcastBoardSheet.choose`).
    var open: @MainActor (BroadcastBoard.Opens) -> Void = { _ in }
    var pause: @MainActor () -> Void = {}
    var resume: @MainActor () -> Void = {}
    /// `confirming`: End Broadcast… asks first; End Broadcast from a complete broadcast does not.
    var end: @MainActor (_ confirming: Bool) -> Void = { _ in }
    var startFresh: @MainActor () -> Void = {}
    /// An end picked from a row's menu (`OperatorController.changeEnd`).
    var changeEnd: @MainActor (_ task: UUID, _ end: TaskEnd) -> Void = { _, _ in }
    /// A choice or Send in a question's block under Waiting on you (`OperatorController.answer(question:in:with:)`): fix
    /// rounds' One More Round and Accept As It Is too.
    var answer: @MainActor (_ key: String, _ text: String) -> Void = { _, _ in }
    /// One of the Operator's items of a row's menu, picked (`AppController.perform(_:on:)`).
    var perform: @MainActor (_ item: OperatorMenuItem, _ task: UUID) -> Void = { _, _ in }
}

/// A question the sheet is asked to show, from a notification's click or the Operator row's: the sheet goes to the Tasks
/// tab, its top, and shows that question in Waiting on you, or the oldest that still waits once it has gone. Each ask is
/// new, so the same question asked again is shown again.
struct BoardFocus: Equatable, Sendable {
    var run: UUID
    var key: String
    var id = UUID()
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

/// The broadcast's sheet (spec §4, §13; rebuilt 14 Nov 2026), `Sheet.width` by `Sheet.boardHeight` in `SheetLayout`'s
/// anatomy: the title; under it the broadcast's `BroadcastStatusLine` as its row says it; then one line of the brief,
/// Asked, cut at its end with the whole brief in its tooltip; then, standing on the header's rule, the underline
/// `TabBar`, Tasks · Activity, picked by click, ← → or ⌘1 and ⌘2. It always opens on Tasks.
///
/// **Tasks** is one scroll, its sections `Space.block` apart and each only while it has something: Waiting on you, one
/// question at a time (`WaitingOnYou`); the Operator's summary once the broadcast reached it (`BroadcastSummaryView`);
/// Left for you from its first item (`LeftForYouList`); the tasks, a `BoardHeading` per stage in `BroadcastBoard.listed`'s
/// order over a `BoardRow` each, or one muted line while nothing is planned; and Worked around in AiTerm
/// (`WorkedAroundList`). A row's click closes the sheet first, then opens what resolves it (`choose`), except that a task
/// with a question answered in the sheet shows that question instead (`shows`). **Activity** is the run's log
/// (`BroadcastActivityView`), what changed until Show everything. The footer is the same on both tabs. Equatable by what
/// it draws, its actions left out (they act on the broadcast as it is when pressed), so the host's `.equatable()` skips
/// a body that would draw the same; the feed redraws Activity alone.
struct BroadcastBoardSheet: View, Equatable {
    let board: BroadcastBoard
    let reopenFailed: Bool
    let actions: BoardActions
    /// The question to show, when one was asked for.
    var focus: BoardFocus? = nil
    /// The run's activity log as the host follows it; nil where Activity is handed its `entries` instead.
    let activity: ActivityFeed?
    /// What Activity lists without a feed, and the row it opens with: the snapshots' (`seeded(tab:entries:open:)`).
    private(set) var entries: [ActivityEntry] = []
    private(set) var openEntry: UUID?
    @State private var tab: BroadcastBoard.Tab = .tasks
    /// The question Waiting on you shows: the pager's (`QuestionPager`).
    @State private var shownQuestion: String?
    /// What was typed under Waiting on you and not sent, by question: the sheet's, so a look at Activity keeps it.
    @State private var drafts: [String: String] = [:]
    /// Activity lists every call, the looking too, once Show everything was picked: until the sheet closes.
    @State private var showsEverything = false
    @Environment(\.dismiss) private var dismiss
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.board == rhs.board && lhs.reopenFailed == rhs.reopenFailed && lhs.activity === rhs.activity && lhs.entries == rhs.entries
            && lhs.openEntry == rhs.openEntry && lhs.focus == rhs.focus
    }

    init(board: BroadcastBoard, reopenFailed: Bool, actions: BoardActions, activity: ActivityFeed?, focus: BoardFocus? = nil) {
        self.board = board; self.reopenFailed = reopenFailed; self.actions = actions; self.activity = activity; self.focus = focus
        _shownQuestion = State(initialValue: focus?.key)
    }

    /// The Tasks tab's top, where the sheet scrolls to show a question.
    static let topId = "board-top"

    /// A row's click: the sheet closes, then what the row opens comes forward. A Todo task has nothing to
    /// open and is no button, so nothing happens.
    @MainActor static func choose(_ opens: BroadcastBoard.Opens, dismiss: () -> Void, actions: BoardActions) {
        guard isButton(opens) else { return }
        dismiss()
        actions.open(opens)
    }

    /// Whether a row that opens this is a button.
    static func isButton(_ opens: BroadcastBoard.Opens) -> Bool { opens != .nothing }

    /// The question a click on `task`'s row shows in the sheet instead of opening a window: its oldest one that still
    /// waits and is answered here. Nil for a task with none, whose row opens what its card says (`Card.opens`): a
    /// permission prompt is answered in its own window, so its row goes there at once.
    static func shows(_ task: UUID, on board: BroadcastBoard) -> String? {
        board.waiting.first { $0.task == task && $0.answered == nil && $0.isAnsweredHere }?.key
    }

    /// ⌘1 and ⌘2 pick the tabs in the order the tab bar draws them.
    static func key(of tab: BroadcastBoard.Tab) -> KeyEquivalent {
        KeyEquivalent(Character(String(BroadcastBoard.Tab.allCases.firstIndex(of: tab)! + 1)))
    }

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(board.runId)
        #endif
        let footer = BoardFooter(board, reopenFailed: reopenFailed)
        ScrollViewReader { proxy in
        SheetLayout(title: board.title, height: .fixed(Sheet.boardHeight), headerEndsInTabs: true, contentVerticalPadding: Space.block) {
            VStack(alignment: .leading, spacing: Space.block) {
                VStack(alignment: .leading, spacing: Space.base) {
                    BroadcastStatusLine(line: board.band, progress: board.progress)
                    if let asked = board.headerLines.first { Self.headerLine(asked, brief: board.brief) }
                }
                tabBar
            }
        } content: {
            switch tab {
            case .tasks: tasks(proxy)
            case .activity:
                if let activity {
                    ActivityFeedView(feed: activity, titles: titles, showsEverything: $showsEverything)
                } else {
                    BroadcastActivityView(entries: entries, titles: titles, openId: openEntry, showsEverything: $showsEverything)
                }
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
        // ⌘1 and ⌘2, on hidden buttons, as Settings' ⌘1–⌘4: the tab bar's tabs are not buttons of their own.
        .modifier(TabShortcuts(items: BroadcastBoard.Tab.allCases, title: \.title, key: Self.key(of:), select: { tab = $0 }))
        // A question asked for: Tasks, its top, and that question in the pager.
        .task(id: focus?.id) {
            guard let focus, focus.run == board.runId else { return }
            show(focus.key, proxy)
        }
        }
    }

    /// `key`'s question in Waiting on you, in view.
    private func show(_ key: String, _ proxy: ScrollViewProxy) {
        tab = .tasks
        shownQuestion = key
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(Self.topId, anchor: .top)
        }
    }

    /// Settings' tab bar, the underline `TabBar`.
    private var tabBar: some View {
        TabBar(values: BroadcastBoard.Tab.allCases, selection: $tab) { item in Text(item.title) }
    }

    /// The Tasks tab, top to bottom.
    private func tasks(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: Space.block) {
            if !board.waiting.isEmpty {
                WaitingOnYou(questions: board.waiting, shown: $shownQuestion, actions: actions, choose: choose, drafts: $drafts)
            }
            if board.summary != .notYet { BroadcastSummaryView(summary: board.summary, goalOutcome: board.goalOutcome) }
            if !board.leftForYou.isEmpty { LeftForYouList(items: board.leftForYou) }
            if board.listed.isEmpty {
                HelpText(BroadcastBoard.nothingPlanned, fixedVerticalSize: false)
            } else {
                VStack(alignment: .leading, spacing: Space.base) {
                    ForEach(board.listed) { lane in stage(lane, proxy) }
                }
            }
            if !board.snags.isEmpty { WorkedAroundList(board: board) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(Self.topId)
    }

    /// The board's tasks' titles by id, for Activity's lines.
    private var titles: [UUID: String] {
        Dictionary(board.stages.flatMap(\.cards).map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    private func choose(_ opens: BroadcastBoard.Opens) {
        Self.choose(opens, dismiss: { dismiss.afterThisEvent() }, actions: actions)
    }

    /// A stage: its heading over its rows, which stand `Space.base` past the content's margins, as Activity's do.
    private func stage(_ lane: BroadcastBoard.Lane, _ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            BoardHeading(title: lane.title, count: lane.cards.count)
            ForEach(lane.cards) { card in
                let question = Self.shows(card.id, on: board)
                BoardRow(card: card, question: question, actions: actions) {
                    if let question { show(question, proxy) } else { choose(card.opens) }
                }
                .equatable()
                .padding(.horizontal, -Space.base)
            }
        }
    }

    /// The header's line of the brief: its label in `Palette.text` at medium weight, the rest muted, in
    /// `Typography.help`, one line cut at its end; `brief`, the whole of it, is its tooltip and what VoiceOver reads.
    private static func headerLine(_ clause: BroadcastBoard.Clause, brief: String) -> some View {
        HelpText(Text("\(Text(verbatim: clause.label).fontWeight(.medium).foregroundStyle(Palette.text)) \(clause.text)"),
                 fixedVerticalSize: false)
            .lineLimit(1).truncationMode(.tail).help(brief)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(brief)
    }
}

#if DEBUG
extension BroadcastBoardSheet {
    /// The sheet already on `tab`, Activity listing `entries` with `open` open and, with `everything`, the looking too:
    /// what only clicks and a run folder reach in the app, for the snapshots.
    func seeded(tab: BroadcastBoard.Tab, entries: [ActivityEntry] = [], open: UUID? = nil, everything: Bool = false) -> Self {
        var sheet = self
        sheet._tab = State(initialValue: tab)
        sheet._showsEverything = State(initialValue: everything)
        sheet.entries = entries
        sheet.openEntry = open
        return sheet
    }

    /// The sheet with Waiting on you on `key`'s question: what only the pager's clicks reach, for the snapshots.
    func showing(question key: String) -> Self {
        var sheet = self
        sheet._shownQuestion = State(initialValue: key)
        return sheet
    }
}
#endif

/// Activity as the run's feed has it: this view alone reads the feed, so an append redraws the list and not
/// the sheet around it.
private struct ActivityFeedView: View {
    let feed: ActivityFeed
    let titles: [UUID: String]
    @Binding var showsEverything: Bool

    var body: some View { BroadcastActivityView(entries: feed.entries, titles: titles, showsEverything: $showsEverything) }
}

/// A section's head on the sheet: a `SidebarHeading` and its count in `Typography.chip.tabular`, `Size.menuRow` tall.
/// With no count, the heading alone.
struct BoardHeading: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: Space.snug) {
            SidebarHeading(title)
            if let count { Text(verbatim: "\(count)").font(Typography.chip.tabular).foregroundStyle(Palette.muted) }
        }
        .frame(height: Size.menuRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
    }
}

/// A task on the sheet (14 Nov 2026): the sidebar's driven-task row, from the same parts. `SidebarRowContent` lays out
/// its `AvatarGroupView`, then the title (`RowTitle`, in the secondary ink while it is queued) over a `Size.chip` line:
/// the task's `OperatorBadge`, or `taken over` with no badge, and trailing it the quiet Jira and merge-request `Badge`s a
/// task row wears (`TaskBadges`); then the row's `TaskRowMarkView`, the mark its sidebar row has. `Space.base` inside,
/// `Size.row` tall, in a `RowPill` on the sheet's ground that washes it while hovered.
///
/// Under its status line, on the title's edge, the one line a row may add (`Card.help`): why its worktree was kept, what its closing
/// waits for, or that the Oracle refused its merge, the reason in that line's tooltip. Its own tooltip is its project
/// when the broadcast spans several, the model the Operator chose and why, and what its worker asks the Operator
/// (`Card.tooltip`).
///
/// Its click closes the sheet and brings forward what resolves it, or shows its question in Waiting on you when it has
/// one answered there (`question`); a task not started, and every row of a shelved board, is no button. Its menu,
/// while the Operator drives it: its end, the four ends under `Cart drawer ends at`, the current one ticked and those
/// the Merge slice keeps out disabled; then the Operator's items of its sidebar row (Take Over or Hand Back, Stop
/// Task…). No test opens the menu: AppKit's menu tracking blocks inside `sendEvent` until it closes. Equatable by its
/// card and the question its click shows, so a change to another task redraws this row not at all, and answering one of
/// its questions redraws it for the next; it reads nothing of the app's live state while it draws, its menu included,
/// for the same reason.
struct BoardRow: View, Equatable {
    let card: BroadcastBoard.Card
    /// The question its click shows in the sheet instead of opening a window, by its key; nil when it opens what its
    /// card says. Compared, since the click's closure holds it: a second question of the task is another row.
    let question: String?
    let actions: BoardActions
    let click: () -> Void
    @State private var hovered = false
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.card == rhs.card && lhs.question == rhs.question }

    init(card: BroadcastBoard.Card, question: String? = nil, actions: BoardActions, click: @escaping () -> Void) {
        self.card = card; self.question = question; self.actions = actions; self.click = click
    }

    private var showsQuestion: Bool { question != nil }

    /// Whether the row is a button: it opens something, or shows its question.
    static func isButton(_ card: BroadcastBoard.Card, showsQuestion: Bool) -> Bool {
        showsQuestion || BroadcastBoardSheet.isButton(card.opens)
    }

    /// What VoiceOver says the row's click does.
    static func hint(_ card: BroadcastBoard.Card, showsQuestion: Bool) -> String {
        showsQuestion ? "Shows its question under Waiting on you." : hint(opens: card.opens)
    }

    /// What VoiceOver says opening `opens` does: a row's click, or a question's button.
    static func hint(opens: BroadcastBoard.Opens) -> String {
        switch opens {
        case .taskWindow: "Opens the task’s window."
        case .prompt: "Brings its tab to the front."
        case .operatorWindow: "Opens the Operator’s window."
        case .sidebarBanner: "Shows the problem in the sidebar’s banner."
        case .nothing: ""
        }
    }

    /// The row's mark, as its sidebar row decides it.
    static func mark(of card: BroadcastBoard.Card) -> TaskRowMark {
        TaskRowMark(status: card.status, line: card.line, removing: false, queued: card.queued, paused: card.paused)
    }

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(card.id)
        #endif
        VStack(alignment: .leading, spacing: 0) {
            if Self.isButton(card, showsQuestion: showsQuestion) {
                Button(action: click) { row }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(Self.hint(card, showsQuestion: showsQuestion)))
            } else {
                row
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(RowPill(selected: false, hovered: hovered && Self.isButton(card, showsQuestion: showsQuestion), ground: .sheet))
        .onHover { hovered = $0 }
        .help(card.tooltip ?? "")
        .contextMenu { menu }
    }

    private var row: some View {
        SidebarRowContent(avatars: card.avatars) {
            VStack(alignment: .leading, spacing: Space.tight) {
                RowTitle(card.title, dimmed: card.queued)
                HStack(spacing: Space.gap) {
                    if card.takenOver {
                        Text("taken over").font(Typography.help).foregroundStyle(Palette.muted)
                    } else if let line = card.line {
                        OperatorBadge(line: line)
                    }
                    Spacer(minLength: Space.gap)
                    TaskBadges(ticket: card.ticket, ticketSummary: card.ticketSummary, mr: card.mr, mrHost: card.mrHost, mrTitle: card.mrTitle)
                }
                .frame(height: Size.chip)
                if let help = card.help { HelpText(help).help(card.mergeRefusal ?? "") }
            }
        } mark: {
            TaskRowMarkView(mark: Self.mark(of: card), size: Size.statusMark)
        }
        .padding(Space.base)
        .frame(minHeight: Size.row)
        .contentShape(Rectangle())
    }

    /// The task's end, then the Operator's items its sidebar row has.
    @ViewBuilder private var menu: some View {
        if let end = card.end {
            Section("\(card.title) ends at") {
                ForEach(TaskEnd.allCases, id: \.self) { item in
                    Toggle(item.title, isOn: Binding(get: { item == end.current }, set: { if $0 { actions.changeEnd(card.id, item) } }))
                        .disabled(!end.selectable.contains(item))
                }
            }
        }
        // From the card's own facts: a closure reading the app's state here would redraw every row with it.
        if let stoppable = card.stoppable {
            OperatorMenuButtons(items: OperatorMenus.task(takenOver: card.takenOver, stoppable: stoppable)) { actions.perform($0, card.id) }
        }
    }
}

/// A task's quiet ticket and merge-request `Badge`s, as a task row wears them: a GitLab issue beside
/// a GitLab merge request shares one mark, `#53` then `!29` `Space.snug` apart.
struct TaskBadges: View {
    let ticket: String?
    let ticketSummary: String?
    let mr: String?
    let mrHost: CodeHost?
    let mrTitle: String?
    var ticketIsGitLabIssue = false

    var body: some View {
        let host = mrHost ?? .gitLab
        QuietBadgeLine(ticket: ticket.map { QuietBadgeValue(label: $0, icon: .brand(ticketIsGitLabIssue ? Palette.gitlab : Palette.jira), help: ticketSummary) },
                       request: mr.map { QuietBadgeValue(label: $0, icon: .brand(host.brand), help: mrTitle) },
                       sharesMark: ticketIsGitLabIssue && host == .gitLab,
                       fixed: true)
    }

}
