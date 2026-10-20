import SwiftUI
import AiTermUI
import AiTermCore

/// What the board's cards and buttons do, handed in by `AppController.boardActions(for:dismiss:)`; a
/// snapshot or a test hands in none.
struct BoardActions {
    /// A card's or a Delivered row's click, the sheet already closed (`BroadcastBoardSheet.choose`).
    var open: @MainActor (BroadcastBoard.Opens) -> Void = { _ in }
    var pause: @MainActor () -> Void = {}
    var resume: @MainActor () -> Void = {}
    /// `confirming`: End Broadcast… asks first; the debrief's End Broadcast does not.
    var end: @MainActor (_ confirming: Bool) -> Void = { _ in }
    var startFresh: @MainActor () -> Void = {}
}

/// The board's footer at each moment (spec §9, §13): Pause Broadcast or Resume Broadcast and End
/// Broadcast… while it runs; End Broadcast on ⌘↩ once it is the debrief, asking nothing; and when the
/// Operator's window could not be reopened, a Notice saying so with Start Fresh on ⌘↩. The debrief
/// outranks a failed reopening: it keeps End Broadcast on ⌘↩, the Notice still shown and Start Fresh a
/// plain button beside it. Close (⎋) always.
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
        notice = reopenFailed
            ? NoticeText(title: "Couldn’t reopen the Operator’s window",
                         description: "Its conversation couldn’t be resumed. A fresh one starts from the board and what it decided so far.")
            : nil
        if board.debrief != nil {
            leading = reopenFailed ? [.startFresh] : []; primary = .end
        } else if reopenFailed {
            // End Broadcast… stays in the row's menu.
            leading = []; primary = .startFresh
        } else {
            leading = [board.isPaused ? .resume : .pause, .endConfirm]; primary = nil
        }
    }
}

/// The broadcast's board (spec §4, §13), `Sheet.boardWidth` by `Sheet.height` in `SheetLayout`'s
/// anatomy: the title; a band line, the broadcast's `BroadcastStatusLine` as its row says it; then the
/// Asked line, two lines at most, the whole of it in its tooltip. Under them the columns, each
/// a `SidebarHeading` and its count over its cards, scrolling on its own; once every task is done, the
/// debrief in their place (`BroadcastDebriefView`). A card's click closes the sheet first, then opens what
/// resolves it (`choose`). Equatable by what it draws, its actions left out (they act on the broadcast
/// as it is when pressed), so the host's `.equatable()` skips a body that would draw the same.
struct BroadcastBoardSheet: View, Equatable {
    let board: BroadcastBoard
    let reopenFailed: Bool
    let actions: BoardActions
    @Environment(\.dismiss) private var dismiss
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.board == rhs.board && lhs.reopenFailed == rhs.reopenFailed
    }

    init(board: BroadcastBoard, reopenFailed: Bool, actions: BoardActions) {
        self.board = board; self.reopenFailed = reopenFailed; self.actions = actions
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

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(board.runId)
        #endif
        let footer = BoardFooter(board, reopenFailed: reopenFailed)
        SheetLayout(title: board.title, height: Sheet.height, width: Sheet.boardWidth, bandHeight: nil, scrolls: false,
                    contentVerticalPadding: Space.block) {
            VStack(alignment: .leading, spacing: Space.base) {
                BroadcastStatusLine(line: board.band, progress: board.progress)
                Self.asked(board.clauses).font(Typography.help).foregroundStyle(Palette.muted)
                    .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true).help(board.asked)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } content: {
            if let debrief = board.debrief {
                BroadcastDebriefView(debrief: debrief, choose: choose)
            } else {
                HStack(alignment: .top, spacing: Space.gap) {
                    ForEach(board.columns) { lane in column(lane) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                    ForEach(lane.cards) { card in BoardCardView(card: card, choose: { choose(card.opens) }).equatable() }
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

/// A column's or a debrief list's head: a `SidebarHeading` and its count in `Typography.monoChip`,
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

/// A column's own scroll: a `ScrollView`, or in the snapshots — whose `ImageRenderer` cannot materialise
/// one — its content clipped at the top.
struct BoardScroll<Content: View>: View {
    @ViewBuilder let content: Content
    #if DEBUG
    @Environment(\.snapshotRendering) private var isSnapshot
    #else
    private let isSnapshot = false
    #endif

    var body: some View {
        if isSnapshot {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        } else {
            ScrollView { content.frame(maxWidth: .infinity, alignment: .topLeading) }.scrollIndicators(.automatic)
        }
    }
}

/// A task on the board (spec §4, §13): a `groupChrome` box, `Space.inset` inside. Its agent's
/// `VendorMark` on every card, started or not (spec §15.4), and beside it, on the title's leading edge as
/// on a task row, the title, two lines at most; then the quiet Jira and merge-request `Badge`s a task row
/// wears, and the project when the broadcast spans several, never the branch; then its status line, one
/// `Size.chip` line: the task's `OperatorBadge`, or `taken over` with no badge. A card
/// that needs you has its edge in `Palette.statusChipAttentionStroke` and the needs-you badge, nothing more:
/// the card is the action. Its tooltip is the model the Operator chose and why. Equatable by its card
/// alone, so a change to another card redraws this one not at all.
struct BoardCardView: View, Equatable {
    let card: BroadcastBoard.Card
    let choose: () -> Void
    @State private var hovered = false
    #if DEBUG
    @Environment(\.rowBodyCounter) private var bodyCounter
    #endif

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.card == rhs.card }

    var body: some View {
        #if DEBUG
        let _ = bodyCounter?.count(card.id)
        #endif
        if BroadcastBoardSheet.isButton(card.opens) {
            Button(action: choose) { box }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .accessibilityHint(Text(Self.hint(card.opens)))
        } else {
            box
        }
    }

    private var box: some View {
        HStack(alignment: .top, spacing: Space.base) {
            if let agent = card.agent { VendorMark(agent: agent.session, size: Size.avatar) }
            lines
        }
        .padding(Space.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupChrome(fill: hovered ? Palette.rowHoverSolid : Palette.surface,
                     edge: card.needsYou ? Palette.statusChipAttentionStroke : Palette.border)
        .contentShape(Rectangle())
        .help(card.modelTooltip ?? "")
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
        case .operatorWindow: "Opens the Operator’s window."
        case .sidebarBanner: "Shows the problem in the sidebar’s banner."
        case .nothing: ""
        }
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

/// The debrief (spec §4.2, §13), in the board's place once every task is done: Delivered, every task and
/// its result, in a full-height column on the left that scrolls; on the right, stacked and scrolling,
/// Decided on its own, Found along the way and Left for you, a list with nothing in it left out. A
/// Delivered row is the agent's mark, the title, the quiet Jira and MR `Badge`s and the result in
/// `Typography.mono`, the model and its reason in its tooltip, and opens its task's window.
struct BroadcastDebriefView: View {
    let debrief: BroadcastBoard.Debrief
    let choose: (BroadcastBoard.Opens) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.margin) {
            VStack(alignment: .leading, spacing: Space.tight) {
                BoardHeading(title: "Delivered", count: debrief.delivered.count)
                BoardScroll {
                    VStack(alignment: .leading, spacing: Space.tight) {
                        ForEach(debrief.delivered) { card in delivered(card) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            BoardScroll {
                VStack(alignment: .leading, spacing: Space.section) {
                    ForEach(debrief.sections, id: \.self) { section in list(section) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func delivered(_ card: BroadcastBoard.Card) -> some View {
        Button { choose(card.opens) } label: {
            HStack(spacing: Space.base) {
                if let agent = card.agent { VendorMark(agent: agent.session, size: Size.vendorMark) }
                Text(card.title).font(Typography.caption).foregroundStyle(Palette.text).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: Space.tight)
                TaskBadges(ticket: card.ticket, ticketSummary: card.ticketSummary, mr: card.mr, mrHost: card.mrHost, mrTitle: card.mrTitle)
                if let result = card.result {
                    Text(result).font(Typography.mono).foregroundStyle(Palette.muted).lineLimit(1).fixedSize()
                }
            }
            .frame(minHeight: Size.menuRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(card.modelTooltip ?? "")
        .accessibilityHint(Text(BoardCardView.hint(card.opens)))
    }

    @ViewBuilder
    private func list(_ section: BroadcastBoard.Debrief.Section) -> some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            switch section {
            case .decided:
                BoardHeading(title: "Decided on its own", count: debrief.decided.count)
                ForEach(Array(debrief.decided.enumerated()), id: \.offset) { _, decision in
                    item(decision.text, why: decision.reason)
                }
            case .finds:
                BoardHeading(title: "Found along the way", count: debrief.finds.count)
                ForEach(Array(debrief.finds.enumerated()), id: \.offset) { _, find in
                    item(find.title, why: find.why, ticket: find.ticket)
                }
            case .leftForYou:
                BoardHeading(title: "Left for you", count: debrief.leftForYou.count)
                ForEach(Array(debrief.leftForYou.enumerated()), id: \.offset) { _, text in item(text, why: nil) }
            }
        }
    }

    private func item(_ text: String, why: String?, ticket: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Space.hairline) {
            HStack(alignment: .firstTextBaseline, spacing: Space.base) {
                Text(text).font(Typography.caption).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
                if let ticket { Badge(ticket, icon: .brand(Palette.jira), style: .quiet).fixedSize() }
            }
            if let why, !why.isEmpty {
                Text(why).font(Typography.help).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
    }
}
