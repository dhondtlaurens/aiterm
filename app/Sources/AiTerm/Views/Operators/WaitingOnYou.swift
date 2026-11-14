import SwiftUI
import AiTermUI
import AiTermCore

/// Which question Waiting on you shows, and where its pager goes from it (14 Nov 2026): rules apart from the view, so
/// each is tested without drawing it. The questions are `BroadcastBoard.waiting`'s, oldest first; an answered one stays
/// among them until the Operator takes it.
enum QuestionPager {
    typealias Question = BroadcastBoard.ListedQuestion

    /// The question shown: `key`'s while it is listed; else the oldest that still waits; else, all answered, the oldest.
    /// Nil with none.
    static func shown(_ key: String?, in questions: [Question]) -> Question? {
        questions.first { $0.key == key } ?? questions.first { $0.answered == nil } ?? questions.first
    }

    /// The key to show once `key`'s question was answered: the next after it that still waits, else the first before it
    /// that does. When nothing else waits, `key` itself: the answered one stays in view, saying what was answered, and
    /// an older answered question never takes its place.
    static func afterAnswering(_ key: String, in questions: [Question]) -> String {
        guard let index = questions.firstIndex(where: { $0.key == key }) else { return questions.first { $0.answered == nil }?.key ?? key }
        let waits: (Question) -> Bool = { $0.answered == nil && $0.key != key }
        return (questions[(index + 1)...].first(where: waits) ?? questions[..<index].first(where: waits))?.key ?? key
    }

    /// The key `delta` questions from `key`'s, Previous and Next's; nil past either end.
    static func step(_ delta: Int, from key: String, in questions: [Question]) -> String? {
        guard let index = questions.firstIndex(where: { $0.key == key }), questions.indices.contains(index + delta) else { return nil }
        return questions[index + delta].key
    }

    /// `2 of 3`, where `key`'s question stands.
    static func position(of key: String, in questions: [Question]) -> String {
        "\((questions.firstIndex { $0.key == key } ?? 0) + 1) of \(questions.count)"
    }
}

/// Waiting on you (14 Nov 2026): every open question for the person, one shown at a time, at the top of the Tasks tab.
/// A `BoardHeading`, `Waiting on you` and how many are listed; with more than one, trailing it, the pager: Previous and
/// Next as links in `Typography.help`, faded at either end, around `2 of 3` in `Typography.chip.tabular`. Then the
/// shown question's `QuestionBlock`. Nothing at all while nothing waits. It opens on the oldest question that still waits;
/// answering shows the next that does (`QuestionPager`); `shown`, the sheet's, puts a question asked for in view. What
/// is typed stays with its question while the sheet is open (`drafts`, the sheet's too, so the Activity tab keeps it).
struct WaitingOnYou: View {
    let questions: [BroadcastBoard.ListedQuestion]
    /// The key of the question shown, when one was picked or asked for.
    @Binding var shown: String?
    let actions: BoardActions
    /// What a button that opens a window does: the sheet closes first (`BroadcastBoardSheet.choose`).
    let choose: (BroadcastBoard.Opens) -> Void
    /// What was typed and not sent, by question.
    @Binding var drafts: [String: String]

    var body: some View {
        if let question = QuestionPager.shown(shown, in: questions) {
            VStack(alignment: .leading, spacing: Space.base) {
                HStack(spacing: Space.gap) {
                    BoardHeading(title: "Waiting on you", count: questions.count)
                    Spacer(minLength: 0)
                    if questions.count > 1 { pager(question.key) }
                }
                QuestionBlock(question: question, text: draft(of: question.key), choose: choose) { answer in
                    actions.answer(question.key, answer)
                    drafts[question.key] = nil
                    shown = QuestionPager.afterAnswering(question.key, in: questions)
                }
                // Its own state, the discussion open or not, starts over with each question.
                .id(question.key)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func draft(of key: String) -> Binding<String> {
        Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0 })
    }

    private func pager(_ key: String) -> some View {
        HStack(spacing: Space.base) {
            step("Previous", -1, from: key)
            Text(verbatim: QuestionPager.position(of: key, in: questions)).font(Typography.chip.tabular).foregroundStyle(Palette.muted)
                .accessibilityLabel("Question \(QuestionPager.position(of: key, in: questions))")
            step("Next", 1, from: key)
        }
        .frame(height: Size.menuRow)
    }

    /// Previous or Next: a link, faded and disabled past its end.
    private func step(_ title: String, _ delta: Int, from key: String) -> some View {
        let target = QuestionPager.step(delta, from: key, in: questions)
        return Button(title) { if let target { shown = target } }
            .buttonStyle(.link).font(Typography.help)
            .disabled(target == nil).opacity(target == nil ? Opacity.disabled : 1)
            .accessibilityLabel("\(title) question")
    }
}

/// One question for you (14 Nov 2026): the same block whoever asks and however it is answered. A `groupChrome` box
/// edged in `Palette.statusChipAttentionStroke` while it waits, `Space.gap` inside and its lines `Space.base` apart, in
/// this order:
///
/// 1. On a `Size.chip` line, its task's quiet Jira `Badge` and title in `Typography.help`, and trailing them who asks or
///    where it waits and its age, `The Operator asks · 24 min`, in `Typography.chip.tabular`.
/// 2. The question in `Typography.body`.
/// 3. At most one line of context in a `HelpText`: a fix-rounds question's verdict counts (`note`), or why a relayed
///    question reached you (`why`) with Read the discussion as a link beside it, which opens the Oracle's rounds and
///    the Operator's replies under it.
/// 4. Its answers, secondary push buttons that wrap as the line fills: its choices; or the one button that opens where
///    it waits, Open Its Window for a worker's prompt (AiTerm never types a permission) and Open the Operator’s Chat for
///    a command the Oracle stopped.
/// 5. Where words are taken, the kit's `Input` with Send beside it, enabled once the field holds text, on ⌘↩.
///
/// A choice or Send calls `send` once. Answered, the edge is `Palette.border` and the answers give way to what you
/// answered, until the Operator resolves the question and it leaves the list.
struct QuestionBlock: View {
    let question: BroadcastBoard.ListedQuestion
    /// What is typed into its field.
    @Binding var text: String
    let choose: (BroadcastBoard.Opens) -> Void
    /// A choice or the typed answer, picked.
    let send: (String) -> Void
    @Environment(\.footerClock) private var clock
    @State private var discussing: Bool = false

    /// The button a question answered elsewhere has: its title, and what it opens.
    static func elsewhere(_ answer: BroadcastBoard.ListedQuestion.Answer) -> (title: String, opens: BroadcastBoard.Opens)? {
        switch answer {
        case .here: nil
        case .window(let task, let tab): ("Open Its Window", .prompt(task: task, tab: tab))
        case .chat: ("Open the Operator’s Chat", .operatorWindow)
        }
    }

    /// The line trailing the block's head: who asks or where it waits, then its age.
    static func asker(_ question: BroadcastBoard.ListedQuestion, now: Date) -> String {
        "\(question.from) · \(BroadcastBoard.age(since: question.askedAt, now: now))"
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = clock?.now ?? context.date
            VStack(alignment: .leading, spacing: Space.base) {
                head(now: now)
                Text(verbatim: question.text).font(Typography.body).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if let note = question.note { HelpText(note, fixedVerticalSize: false) }
                if let why = question.why { discussion(why) }
                if let answered = question.answeredLine(now: now) {
                    HelpText(answered, fixedVerticalSize: false)
                } else {
                    answers
                }
            }
            .padding(Space.gap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .groupChrome(fill: Palette.surfaceRaised,
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
        HStack(spacing: Space.base) {
            if let ticket = question.ticket {
                QuietBadgeLine(ticket: QuietBadgeValue(label: ticket, icon: .brand(Palette.jira)), fixed: true)
            }
            Text(question.title).font(Typography.help).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: Space.gap)
            Text(verbatim: Self.asker(question, now: now)).font(Typography.chip.tabular)
                .foregroundStyle(Palette.muted).lineLimit(1).fixedSize()
        }
        .frame(height: Size.chip)
    }

    /// The buttons, then the field where words are taken.
    @ViewBuilder private var answers: some View {
        if let elsewhere = Self.elsewhere(question.answer) {
            Button(elsewhere.title) { choose(elsewhere.opens) }.buttonStyle(.push(.secondary))
                .accessibilityHint(Text(BoardRow.hint(opens: elsewhere.opens)))
        }
        if case .here(let choices, let field) = question.answer {
            if !choices.isEmpty {
                ButtonFlow(spacing: Space.base) {
                    ForEach(choices, id: \.self) { choice in Button(choice) { send(choice) } }
                }
                .buttonStyle(.push(.secondary))
            }
            if field {
                HStack(spacing: Space.base) {
                    Input(placeholder: choices.isEmpty ? "Your answer" : "Another answer", text: $text)
                    let ready = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    // ⌘↩ only once there is something to send, so an empty field never takes it from the footer's button.
                    if ready {
                        Button("Send") { send(text) }.keyboardShortcut(.return, modifiers: .command)
                    } else {
                        Button("Send") {}.disabled(true)
                    }
                }
                .buttonStyle(.push(.secondary))
            }
        }
    }
}

/// Buttons in lines `spacing` apart, wrapping as a line fills: a question's choices.
private struct ButtonFlow: Layout {
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
