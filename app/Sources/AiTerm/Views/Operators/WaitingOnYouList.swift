import SwiftUI
import AiTermUI
import AiTermCore

/// Waiting on you (D1a, 5 Nov 2026): every open question for the person, above the Board tab's columns, oldest first, at
/// the sheet's content width (`Sheet.width` less `Space.margin` each side). A `BoardHeading`, `Waiting on you` and its
/// count, then one `QuestionBlock` each, `Space.gap` apart. Nothing at all while nothing waits. Each block carries its
/// key as its id, so the sheet scrolls to it (`BroadcastBoardSheet.scrollTarget`).
struct WaitingOnYouList: View {
    let questions: [BroadcastBoard.ListedQuestion]
    let actions: BoardActions
    /// What a link that opens a window does: the sheet closes first (`BroadcastBoardSheet.choose`).
    let choose: (BroadcastBoard.Opens) -> Void

    /// The list's width: the sheet's content, not the columns', which scroll sideways under it.
    static let width = Sheet.width - 2 * Space.margin
    /// The block last focused or edited, which alone claims ⌘↩.
    @State private var drafting: String? = nil

    init(questions: [BroadcastBoard.ListedQuestion], actions: BoardActions, choose: @escaping (BroadcastBoard.Opens) -> Void) {
        self.questions = questions; self.actions = actions; self.choose = choose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            BoardHeading(title: "Waiting on you", count: questions.count)
            VStack(alignment: .leading, spacing: Space.gap) {
                ForEach(questions) { question in
                    QuestionBlock(question: question, actions: actions, choose: choose, drafting: $drafting)
                        .id(question.key)
                }
            }
        }
        .frame(width: Self.width, alignment: .leading)
    }
}

/// One question under Waiting on you: a `groupChrome` box edged in `Palette.statusChipAttentionStroke`, as a card that
/// needs you, `Space.block` inside and its lines `Space.base` apart. Its task's quiet Jira `Badge` and title in
/// `Typography.help`, its age trailing in `Typography.monoChip`, on a `Size.chip` line; who asks, or where it waits, in
/// a `HelpText`; the question in `Typography.body`; then how it is answered. **Here**: its choices as links in
/// `Typography.help`, then the kit's `Input` with Send, enabled once the field holds text, ⌘↩ sending it while this is
/// the block focused or typed in last (fix rounds have no field). A choice or Send records the answer once (`OperatorController.answer(question:in:with:)`). **There**: one
/// link, Open its window or Open the Operator's chat. Answered, the edge is `Palette.border` and the block says what you
/// answered, until the Operator resolves the question and it leaves the list.
struct QuestionBlock: View {
    let question: BroadcastBoard.ListedQuestion
    let actions: BoardActions
    let choose: (BroadcastBoard.Opens) -> Void
    /// The key of the block focused or typed in last, which alone owns ⌘↩ (`WaitingOnYouList`).
    @Binding var drafting: String?
    @Environment(\.footerClock) private var clock
    @State private var typed: String = ""
    @State private var discussing: Bool = false

    init(question: BroadcastBoard.ListedQuestion, actions: BoardActions, choose: @escaping (BroadcastBoard.Opens) -> Void,
         drafting: Binding<String?>) {
        self.question = question; self.actions = actions; self.choose = choose; self._drafting = drafting
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = clock?.now ?? context.date
            VStack(alignment: .leading, spacing: Space.base) {
                head(now: now)
                HelpText(question.from)
                Text(verbatim: question.text).font(Typography.body).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let why = question.why { discussion(why) }
                if let answered = question.answeredLine(now: now) {
                    HelpText(answered, fixedVerticalSize: false)
                } else {
                    answer
                }
            }
            .padding(Space.block)
            .frame(maxWidth: .infinity, alignment: .leading)
            .groupChrome(fill: Palette.surface,
                         edge: question.answered == nil ? Palette.statusChipAttentionStroke : Palette.border)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(question.title): \(question.text)")
    }

    /// Why a relayed question reached you, and Read the discussion, which opens the Oracle's rounds and the Operator's
    /// replies under it, each a `HelpText`.
    private func discussion(_ why: String) -> some View {
        VStack(alignment: .leading, spacing: Space.base) {
            HStack(alignment: .firstTextBaseline, spacing: Space.gap) {
                HelpText(why, fixedVerticalSize: false)
                if question.discussion != nil {
                    Button(discussing ? "Hide the discussion" : "Read the discussion") { discussing.toggle() }
                        .buttonStyle(.link).font(Typography.help).fixedSize()
                }
            }
            if discussing, let steps = question.discussion {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    HelpText(step.said, fixedVerticalSize: false)
                }
            }
        }
    }

    private func head(now: Date) -> some View {
        HStack(spacing: Space.gap) {
            if let ticket = question.ticket {
                QuietBadgeLine(ticket: QuietBadgeValue(label: ticket, icon: .brand(Palette.jira)), fixed: true)
            }
            Text(question.title).font(Typography.help).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: Space.gap)
            Text(verbatim: BroadcastBoard.age(since: question.askedAt, now: now)).font(Typography.monoChip).foregroundStyle(Palette.muted)
        }
        .frame(height: Size.chip)
    }

    @ViewBuilder private var answer: some View {
        switch question.answer {
        case .here(let choices, let field):
            if !choices.isEmpty {
                LinkFlow(spacing: Space.gap) {
                    ForEach(choices, id: \.self) { choice in
                        Button(choice) { send(choice) }.buttonStyle(.link).font(Typography.help)
                    }
                }
            }
            if field {
                HStack(spacing: Space.base) {
                    Input(placeholder: choices.isEmpty ? "Your answer" : "Another answer", text: $typed,
                          onFocus: { drafting = question.key })
                        .onChange(of: typed) { _, now in if !now.isEmpty { drafting = question.key } }
                    let ready = !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    // ⌘↩ only in the block focused or typed in last, so it never sends another block's draft.
                    if ready, drafting == question.key {
                        Button("Send") { send(typed) }.keyboardShortcut(.return, modifiers: .command)
                    } else if ready {
                        Button("Send") { send(typed) }
                    } else {
                        Button("Send") {}.disabled(true)
                    }
                }
            }
        case .window(let task, let tab):
            Button("Open its window") { choose(.prompt(task: task, tab: tab)) }.buttonStyle(.link).font(Typography.help)
                .accessibilityHint(Text(BoardCardView.hint(.prompt(task: task, tab: tab))))
        case .chat:
            Button("Open the Operator’s chat") { choose(.operatorWindow) }.buttonStyle(.link).font(Typography.help)
                .accessibilityHint(Text(BoardCardView.hint(.operatorWindow)))
        }
    }

    private func send(_ text: String) {
        actions.answer(question.key, text)
        typed = ""
        if drafting == question.key { drafting = nil }
    }
}

/// Links in lines `spacing` apart, wrapping as a line fills: a question's choices.
private struct LinkFlow: Layout {
    let spacing: CGFloat

    private func arrange(_ subviews: Subviews, width proposed: CGFloat?) -> (origins: [CGPoint], size: CGSize) {
        let width = proposed ?? .infinity
        var origins: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width { y += line + spacing; x = 0; line = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + line))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrange(subviews, width: bounds.width).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }
}
