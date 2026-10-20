import Foundation

/// The broadcast's board, the sheet its row opens (spec §4, §4.2, §13), as a value: decided here, apart
/// from the app's `BroadcastBoardSheet`, so each moment is tested without drawing it.
///
/// The header restates the brief: the title, a band line with the broadcast's own status line
/// (`OperatorLine.broadcast`) and `2 of 8 done · webshop, payments-api`, then one Asked line. The board is
/// the plan: Todo · In progress · Review · Done, Review only when the broadcast has a review, each task's
/// card in the column its state puts it in, in the plan's order. Once every task is done (the run is
/// complete) the debrief takes the board's place.
public struct BroadcastBoard: Equatable, Sendable {
    public enum Column: String, CaseIterable, Sendable {
        case todo, inProgress, review, done

        /// Its head, a `SidebarHeading` (which sets it in capitals).
        public var title: String {
            switch self {
            case .todo: "Todo"
            case .inProgress: "In progress"
            case .review: "Review"
            case .done: "Done"
            }
        }
    }

    /// Where a card's click goes once the sheet is closed: what resolves its request, or its task.
    public enum Opens: Equatable, Sendable {
        /// An agent's permission prompt, or a started task with nothing asked: the task's window.
        case taskWindow(UUID)
        /// A question, or a blocked task: the Operator's window, where it is answered.
        case operatorWindow
        /// A problem AiTerm hit: the sidebar banner's Notice already shows the issue, with its recovery.
        case sidebarBanner(issue: String)
        /// A Todo task that has not started: the card is not a button.
        case nothing
    }

    /// One task on the board, and its row in the debrief's Delivered.
    public struct Card: Equatable, Identifiable, Sendable {
        /// The task's id.
        public var id: UUID
        public var title: String
        /// Its agent, started or not (spec §15.4): the mark leading the title.
        public var agent: AgentKind?
        /// Its Jira key, and the ticket's summary for the badge's tooltip.
        public var ticket: String?
        public var ticketSummary: String?
        /// Its merge or pull request, as its host writes it (`!418`), the host, and the request's title.
        public var mr: String?
        public var mrHost: CodeHost?
        public var mrTitle: String?
        /// Its project, only when the broadcast spans more than one.
        public var project: String?
        /// The task's status line (`OperatorLine.task`); nil for a task you took over.
        public var line: OperatorLine?
        /// You took it over: the card reads `taken over` with no badge until you Hand Back.
        public var takenOver: Bool
        /// It carries a request: its edge in the attention stroke, its line the needs-you badge.
        public var needsYou: Bool
        public var opens: Opens
        /// The model the Operator chose and its one-line reason (spec §15.4): `Codex · gpt-5.5 · high`, then
        /// the reason on a line of its own.
        public var modelTooltip: String?
        /// What a finished task ended at (`merged · 9b3e07d`): the debrief's mono result.
        public var result: String?
    }

    /// A column: its head, its cards, and the one muted line it says while it has none.
    public struct Lane: Equatable, Identifiable, Sendable {
        public var column: Column
        public var cards: [Card]
        public var empty: String
        public var id: Column { column }
        public var title: String { column.title }
    }

    /// One part of the Asked line: `Asked`, `Review` or `Done`, then what it says.
    public struct Clause: Equatable, Sendable {
        public var label: String
        public var text: String
        public init(label: String, text: String) { self.label = label; self.text = text }
    }

    /// What the debrief lists beside Delivered: what the Operator decided on its own, found along the way,
    /// and left for you. A list with nothing in it is left out.
    public struct Debrief: Equatable, Sendable {
        public enum Section: Equatable, Sendable { case decided, finds, leftForYou }
        /// Every task the broadcast delivered, in the plan's order.
        public var delivered: [Card]
        public var decided: [OperatorDecision]
        public var finds: [OffBriefFind]
        public var leftForYou: [String]

        /// The right column's lists, stacked in this order, the empty ones left out.
        public var sections: [Section] {
            let lists: [(Section, Bool)] = [(.decided, !decided.isEmpty), (.finds, !finds.isEmpty), (.leftForYou, !leftForYou.isEmpty)]
            return lists.filter(\.1).map(\.0)
        }
    }

    public var runId: UUID
    public var title: String
    /// The broadcast's status line, the band's first part.
    public var band: OperatorLine
    /// `2 of 8 done`; nil until the first plan is in Todo.
    public var progress: String?
    /// Every project the broadcast works in, by name.
    public var projects: [String]
    /// The Asked line's parts: the prompt, then the Review and the Done when it has them.
    public var clauses: [Clause]
    /// The board's columns, Review left out without a review.
    public var columns: [Lane]
    /// Set once every task is done: the debrief takes the board's place.
    public var debrief: Debrief?
    /// Paused by you, or its Operator's window closed: the footer offers Resume Broadcast.
    public var isPaused: Bool

    /// The band's words after the badge: `2 of 8 done · webshop, payments-api`.
    public var bandDetail: String {
        [progress, projects.isEmpty ? nil : projects.joined(separator: ", ")].compactMap { $0 }.joined(separator: " · ")
    }

    /// The Asked line whole, as its tooltip says it.
    public var asked: String { clauses.map { "\($0.label) \($0.text)" }.joined(separator: " · ") }

    /// The board of `run` as `state` has it. `acting` is what the Operator is doing now, as
    /// `OperatorController.acting` says it; `requests` are the broadcast's open requests (`OperatorRequests`).
    public static func make(run: OperatorRun, state: AppState, acting: OperatorActs, requests: [BroadcastRequest]) -> BroadcastBoard {
        let tasks = state.tasks(inRun: run.id)
        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projects = run.projectIds.compactMap(state.project(id:))
        let names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let hasReview = !(run.review ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // A task you stopped is no longer the broadcast's work: it is on no column.
        let cards = tasks.compactMap { task -> (Column, Card, AgentKind)? in
            guard let operated = task.operated, operated.state != .stopped else { return nil }
            let card = Self.card(task, operated, run: run, acting: acting.tasks[task.id], requests: requests, tasks: byId,
                                 project: projects.count > 1 ? names[task.projectId] : nil)
            return (Self.column(of: operated, hasReview: hasReview), card, task.agent)
        }
        let columns = Column.allCases.filter { $0 != .review || hasReview }.map { column in
            Lane(column: column, cards: cards.filter { $0.0 == column }.map(\.1), empty: Self.empty(column, planned: !tasks.isEmpty))
        }
        // Every delivered task wears its agent's mark and opens its window, as a started card does.
        let delivered = cards.map { _, card, agent in
            var row = card
            row.agent = agent
            row.opens = .taskWindow(card.id)
            return row
        }
        let debrief = run.state == .complete
            ? Debrief(delivered: delivered, decided: run.decisions, finds: run.finds, leftForYou: run.leftForYou)
            : nil

        return BroadcastBoard(
            runId: run.id, title: run.name,
            band: OperatorLine.broadcast(run, tasks: tasks, acting: acting.broadcast(run.id), requests: requests),
            progress: progress(of: run, tasks: tasks), projects: projects.map(\.name),
            clauses: [Clause(label: "Asked", text: oneLine(run.prompt))]
                + [("Review", run.review), ("Done", run.done)].compactMap { label, text in
                    text.map(oneLine).flatMap { $0.isEmpty ? nil : Clause(label: label, text: $0) }
                },
            columns: columns, debrief: debrief,
            isPaused: run.state == .paused || run.state == .operatorOffline || run.intent == .paused)
    }

    /// `2 of 8 done`, once the first plan is in Todo: the finished tasks of those not stopped. The broadcast
    /// row's progress too.
    public static func progress(of run: OperatorRun, tasks: [TaskItem]) -> String? {
        guard run.firstPlanSize != nil else { return nil }
        let counted = tasks.filter { $0.operated?.runId == run.id && $0.operated?.state != .stopped }
        let done = counted.filter { ($0.operated?.state).map(SidebarModel.isFinished) ?? false }.count
        return "\(done) of \(counted.count) done"
    }

    // MARK: - A card

    private static func card(_ task: TaskItem, _ operated: OperatedTask, run: OperatorRun, acting: OperatorAct?,
                             requests: [BroadcastRequest], tasks: [UUID: TaskItem], project: String?) -> Card {
        let line = OperatorLine.task(task, run: run, acting: acting, requests: requests, tasks: tasks)
        let takenOver = operated.takenOver
        let mr: (reference: String, host: CodeHost, title: String?)? = task.mr.map { ($0.reference, $0.host, $0.title) }
            ?? operated.publication.flatMap { publication in
                publication.mergeRequestNumber.map { number in
                    let host = CodeHost(webURL: publication.mergeRequestURL ?? "")
                    return (host.reference(number), host, nil)
                }
            }
        return Card(id: task.id, title: task.title, agent: task.agent,
                    ticket: task.jira?.key, ticketSummary: task.jira?.summary,
                    mr: mr?.reference, mrHost: mr?.host, mrTitle: mr?.title, project: project,
                    line: takenOver ? nil : line, takenOver: takenOver,
                    needsYou: !takenOver && line?.look == .needsYou,
                    opens: opens(task, operated, requests: requests),
                    modelTooltip: modelTooltip(task, operated), result: OperatorLine.ending(of: operated))
    }

    /// The column a task's state puts it in. A blocked task stays where it was: In progress once it has
    /// started, Todo while it has not. In review is Review's, or In progress on a board with no Review.
    private static func column(of operated: OperatedTask, hasReview: Bool) -> Column {
        switch operated.state {
        case .planned, .queued: return .todo
        case .blocked: return operated.started ? .inProgress : .todo
        case .working, .failed: return .inProgress
        case .inReview: return hasReview ? .review : .inProgress
        case .accepted, .noChange, .published, .stopped: return .done
        }
    }

    /// What resolves the card's request, by its kind (the one its line says), else its task's window once
    /// it has started. A finished task's leftover request asks nothing, as on its line.
    private static func opens(_ task: TaskItem, _ operated: OperatedTask, requests: [BroadcastRequest]) -> Opens {
        var kind: BroadcastRequest.Kind?
        if !operated.takenOver, !SidebarModel.isFinished(operated.state) {
            kind = OperatorLine.first(requests.filter { $0.runId == operated.runId && $0.taskId == task.id })?.kind
            // Blocked, whether or not its request was passed in: what blocks it is the Operator's, or AiTerm's.
            if kind == nil, operated.state == .blocked { kind = operated.problem == nil ? .blocked : .problem }
        }
        switch kind {
        case .permission?: return .taskWindow(task.id)
        case .question?, .blocked?: return .operatorWindow
        case .problem?:
            guard let issue = operated.problem else { return .operatorWindow }
            return .sidebarBanner(issue: issue)
        case nil: return operated.started ? .taskWindow(task.id) : .nothing
        }
    }

    /// `Codex · gpt-5.5 · high`, and the Operator's reason on the line under it.
    private static func modelTooltip(_ task: TaskItem, _ operated: OperatedTask) -> String? {
        guard !task.model.isEmpty else { return nil }
        let model = ([SidebarModel.agentName(task.agent), task.model] + [task.reasoning].compactMap { $0 }.filter { !$0.isEmpty })
            .joined(separator: " · ")
        guard let reason = operated.modelReason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty else { return model }
        return model + "\n" + reason
    }

    /// The muted line an empty column says.
    private static func empty(_ column: Column, planned: Bool) -> String {
        switch column {
        case .todo: planned ? "Nothing left to start." : "Nothing planned yet."
        case .inProgress: "Nothing started yet."
        case .review: "Nothing in review."
        case .done: "Nothing done yet."
        }
    }

    /// Text as one line: its runs of spaces and newlines each one space.
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}
