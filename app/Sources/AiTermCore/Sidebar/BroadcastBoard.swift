import Foundation

/// The broadcast's board, the sheet its row opens (spec §4, §4.2, §13), as a value: decided here, apart
/// from the app's `BroadcastBoardSheet`, so each moment is tested without drawing it.
///
/// The header restates the brief: the title, a band line with the broadcast's own status line
/// (`OperatorLine.broadcast`) and `· 2 of 8 done` after it, then the Asked line. The board is
/// the plan: Todo · In progress · Review · Done, Review only when the broadcast has a review, each task's
/// card in the column its state puts it in, in the plan's order, and once every task is done they all sit in Done.
/// What the sheet's other tabs read is here too: the Summary's state, what is left for you and what the Operator
/// worked around in AiTerm, and which tab it opens on. An ended broadcast read from the Shelf is a `shelved` board, read-only.
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
        /// A blocked task: the Operator's window, where it is answered.
        case operatorWindow
        /// A problem AiTerm hit: the sidebar banner's Notice already shows the issue, with its recovery.
        case sidebarBanner(issue: String)
        /// One of a task's worker tabs, from its line on the card: that tab selected and its window brought forward.
        case tab(task: UUID, sessionId: String)
        /// A Todo task that has not started: the card is not a button.
        case nothing
    }

    /// One worker tab of a task with several (P5 A, 21 Oct 2026), a line of its card (not one of the sheet's `Tab`s): its agent, its key, what it
    /// does and its mark. A closed tab is listed, muted, with no mark, and is no button; one opening is no button
    /// until iTerm2 lists it.
    public struct TabLine: Equatable, Identifiable, Sendable {
        /// `main` for the first worker (`WorkerTab.firstKey`), else the extra tab's key.
        public var key: String
        public var agent: AgentKind
        /// `at work`, `turn ended`, `in background` (its turn ended with work still running, the jobs on its tooltip),
        /// `waiting on you` (needs you), `opening` or `closed`.
        public var line: OperatorLine
        /// Its `StatusMark`; nil once closed.
        public var status: TaskStatus?
        /// `.tab` while iTerm2 lists it, else `.nothing`.
        public var opens: Opens
        public var id: String { key }
        public var isClosed: Bool { status == nil }

        public init(key: String, agent: AgentKind, line: OperatorLine, status: TaskStatus?, opens: Opens) {
            self.key = key; self.agent = agent; self.line = line; self.status = status; self.opens = opens
        }
    }

    /// What a task's Claude worker says it runs now (`SessionInfo.liveModel`, `.liveReasoning`), which its card's tooltip
    /// holds against the plan.
    public struct LiveModel: Equatable, Sendable {
        public var model: String
        public var reasoning: String?
        public init(model: String, reasoning: String?) { self.model = model; self.reasoning = reasoning }

        /// Whether it is another model or effort than the plan's `model` and `reasoning`. A planned alias (`opus`) is any
        /// model of its family. With no effort planned the worker runs Claude Code's default, and with none said it has
        /// not said which: only the model counts then.
        func differs(fromModel planned: String, reasoning plannedReasoning: String?) -> Bool {
            guard Self.runs(planned, as: model) else { return true }
            guard let plannedReasoning, let reasoning else { return false }
            return reasoning != plannedReasoning
        }

        /// Whether `live`, a model id as Claude Code reports it, is the model `planned` names: the same id, or for one of
        /// Claude's aliases (`ModelFiles.claudeAliases`) a model of its family, whatever its version or context window.
        static func runs(_ planned: String, as live: String) -> Bool {
            guard planned != live else { return true }
            let alias = planned.prefix { $0 != "[" }
            return ModelFiles.claudeAliases.contains(String(alias)) && live.prefix { $0 != "[" }.split(separator: "-").contains(alias)
        }
    }

    /// One task on the board.
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
        /// What a finished task ended at (`merged · 9b3e07d`).
        public var result: String?
        /// Its worker tabs, the first worker's first, while it has more than one; empty otherwise.
        public var tabs: [TabLine] = []
        /// The Oracle’s reason for refusing a merge, separate from the task’s status.
        public var mergeRefusal: String? = nil
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

    /// The sheet's tabs, in the order they are drawn.
    public enum Tab: CaseIterable, Sendable {
        case board, activity, summary

        public var title: String {
            switch self {
            case .board: "Board"
            case .activity: "Activity"
            case .summary: "Summary"
            }
        }
    }

    public var runId: UUID
    public var title: String
    /// The broadcast's status line, the band's first part.
    public var band: OperatorLine
    /// `2 of 8 done`, after the band's status line; nil until the first plan is in Todo.
    public var progress: String?
    /// The Asked line's parts: the prompt, then the Review and the Done when it has them.
    public var clauses: [Clause]
    /// The board's columns, Review left out without a review.
    public var columns: [Lane]
    /// Paused by you, or its Operator's window closed: the footer offers Resume Broadcast.
    public var isPaused: Bool
    /// Every task is done (the run is complete): the footer's End Broadcast, asking nothing.
    public var isComplete: Bool
    /// What the Summary tab says (`RunSummary`).
    public var summary: RunSummary
    /// What the Operator left for you, as `leave_for_you` wrote it: the Summary tab's list.
    public var leftForYou: [String]
    /// What the Operator worked around in AiTerm, as `report_snag` recorded it: the Summary tab's last list.
    public var snags: [OperatorSnag] = []
    /// An ended broadcast read from the Shelf: nothing on it acts, and the footer is Close alone.
    public var isShelved: Bool = false

    /// The Asked line whole, as its tooltip says it.
    public var asked: String { clauses.map { "\($0.label) \($0.text)" }.joined(separator: " · ") }

    /// What a snag's Copy puts on the clipboard: the AiTerm task that fixes it, naming this broadcast.
    public func fixTask(_ snag: OperatorSnag) -> String { snag.fixTask(broadcast: title, runId: runId) }

    /// What Copy All puts on the clipboard: every snag's fix task in the order they were reported, a rule between
    /// each. Nil with fewer than two, where an item's own Copy is all there is.
    public var copyAll: String? {
        snags.count > 1 ? snags.map(fixTask).joined(separator: "\n\n---\n\n") : nil
    }

    /// The tab the sheet opens on: the Summary once there is one to read or a reason there is none, else the Board.
    public var firstTab: Tab { summary == .notYet ? .board : .summary }

    /// Whether `tab` can be selected: the Summary only once the broadcast has reached it.
    public func isSelectable(_ tab: Tab) -> Bool { tab != .summary || summary != .notYet }

    /// The board of `run` as `state` has it. `acting` is what the Operator is doing now, as
    /// `OperatorController.acting` says it; `requests` are the broadcast's open requests (`OperatorRequests`);
    /// `sessions` the tabs as iTerm2 lists them, which the band reads as its row does; `liveModels` what each task's
    /// Claude worker runs now (`liveModels(of:state:sessions:)`), which the cards' tooltips say.
    public static func make(run: OperatorRun, state: AppState, acting: OperatorActs, requests: [BroadcastRequest],
                            sessions: [SessionInfo] = [], liveModels: [UUID: LiveModel] = [:]) -> BroadcastBoard {
        build(run: run, state: state, acting: acting, requests: requests, sessions: sessions, liveModels: liveModels,
              keepsHanded: false)
    }

    /// What the first worker of each of `run`'s tasks says it runs now, a Claude's alone (`SessionInfo.liveModel`), by
    /// task: from `sessions` with their models and efforts, which the tabs as the rows read them leave out
    /// (`SessionInfo.rowRelevant`).
    public static func liveModels(of run: OperatorRun, state: AppState, sessions: [SessionInfo]) -> [UUID: LiveModel] {
        var models: [UUID: LiveModel] = [:]
        for task in state.tasks(inRun: run.id) {
            guard let worker = task.firstWorker(in: sessions), let model = worker.liveModel else { continue }
            models[task.id] = LiveModel(model: model, reasoning: worker.liveReasoning)
        }
        return models
    }

    /// The board, `keepsHanded` keeping the tasks End handed to you (`handedOnEnd`) In progress and counted, as the
    /// Shelf reads an ended broadcast.
    private static func build(run: OperatorRun, state: AppState, acting: OperatorActs, requests: [BroadcastRequest],
                              sessions: [SessionInfo], liveModels: [UUID: LiveModel], keepsHanded: Bool) -> BroadcastBoard {
        let tasks = state.tasks(inRun: run.id)
        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projects = run.projectIds.compactMap(state.project(id:))
        let names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let hasReview = !(run.review ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // A task you stopped is no longer the broadcast's work: it is on no column. One End handed you stays In
        // progress on the Shelf's board, taken over, as it was when the broadcast ended.
        let cards = tasks.compactMap { task -> (Column, Card, AgentKind)? in
            guard let operated = task.operated else { return nil }
            let handed = keepsHanded && Self.handedOnEnd(operated)
            guard operated.state != .stopped || handed else { return nil }
            let card = Self.card(task, operated, run: run, acting: acting.tasks[task.id], requests: requests, tasks: byId, sessions: sessions,
                                 live: liveModels[task.id], turn: acting.turns[task.id], project: projects.count > 1 ? names[task.projectId] : nil)
            return (handed ? .inProgress : Self.column(of: operated, hasReview: hasReview), card, task.agent)
        }
        let columns = Column.allCases.filter { $0 != .review || hasReview }.map { column in
            Lane(column: column, cards: cards.filter { $0.0 == column }.map(\.1), empty: Self.empty(column, planned: !tasks.isEmpty))
        }
        return BroadcastBoard(
            runId: run.id, title: run.name,
            band: OperatorLine.broadcast(run, tasks: tasks, acting: acting.broadcast(run.id), requests: requests,
                                         ready: SidebarModel.readyForAcceptance(tasks, sessions: sessions)),
            progress: progress(of: run, tasks: tasks, keepsHanded: keepsHanded),
            clauses: [Clause(label: "Asked", text: oneLine(run.prompt))]
                + [("Review", run.review), ("Done", run.done)].compactMap { label, text in
                    text.map(oneLine).flatMap { $0.isEmpty ? nil : Clause(label: label, text: $0) }
                },
            columns: columns,
            isPaused: run.isPaused,
            isComplete: run.state == .complete, summary: RunSummary(run), leftForYou: run.leftForYou, snags: run.snags)
    }

    /// The board of an ended `run` for the Shelf: every task it drove, the live ones and those archived since, in the
    /// order they were created (the state's order where that ties), and no card a button, no worker tab listed, nothing
    /// paused. Nothing is live: no acts, no requests, no sessions. What End handed you, mid-flight, stays In progress
    /// reading `taken over` and counts towards the total, not as done: a broadcast ended at 2 of 8 says so.
    public static func shelved(run: OperatorRun, state: AppState) -> BroadcastBoard {
        var all = state
        let driven = state.tasks(inRun: run.id) + state.archive.map(\.task).filter { $0.operated?.runId == run.id }
        all.tasks = driven.enumerated().sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }.map(\.element)
        var board = build(run: run, state: all, acting: .none, requests: [], sessions: [], liveModels: [:], keepsHanded: true)
        board.columns = board.columns.map { lane in
            var lane = lane
            lane.cards = lane.cards.map { card in
                var card = card
                card.opens = .nothing
                card.tabs = []
                return card
            }
            return lane
        }
        board.isPaused = false
        board.isShelved = true
        return board
    }

    /// `2 of 8 done`, once the first plan is in Todo: the finished tasks of those not stopped, as the board's
    /// band says it.
    static func progress(of run: OperatorRun, tasks: [TaskItem], keepsHanded: Bool = false) -> String? {
        count(of: run, tasks: tasks, keepsHanded: keepsHanded).map { $0 + " done" }
    }

    /// `2 of 8`, the progress as the broadcast's header in the sidebar says it; nil until the first plan is
    /// in Todo. A stopped task is not counted, unless `keepsHanded` and End handed it to you.
    static func count(of run: OperatorRun, tasks: [TaskItem], keepsHanded: Bool = false) -> String? {
        guard run.firstPlanSize != nil else { return nil }
        let counted = tasks.filter { task in
            guard let operated = task.operated, operated.runId == run.id else { return false }
            return operated.state != .stopped || (keepsHanded && handedOnEnd(operated))
        }
        // A handed task is stopped, which `isFinished` counts as an end: it was not done.
        let done = counted.filter { $0.operated.map { $0.isFinished && !handedOnEnd($0) } ?? false }.count
        return "\(done) of \(counted.count)"
    }

    /// A task End handed you while it was in flight: stopped, and yours (`OperatorController.end`).
    private static func handedOnEnd(_ operated: OperatedTask) -> Bool { operated.state == .stopped && operated.takenOver }

    // MARK: - A card

    private static func card(_ task: TaskItem, _ operated: OperatedTask, run: OperatorRun, acting: OperatorAct?,
                             requests: [BroadcastRequest], tasks: [UUID: TaskItem], sessions: [SessionInfo], live: LiveModel?,
                             turn: WorkerTurn.Ending?, project: String?) -> Card {
        let line = OperatorLine.task(task, run: run, acting: acting, requests: requests, tasks: tasks, sessions: sessions, turn: turn)
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
                    modelTooltip: modelTooltip(task, operated, live: live), result: OperatorLine.ending(of: operated),
                    tabs: tabs(of: task, sessions: sessions),
                    mergeRefusal: takenOver || operated.isFinished ? nil : operated.publication?.mergeRefusal)
    }

    /// A card's tab lines, as `sessions` list its worker tabs; none for a task with one.
    private static func tabs(of task: TaskItem, sessions: [SessionInfo]) -> [TabLine] {
        let workers = task.workerTabs(in: sessions)
        guard workers.count > 1 else { return [] }
        return workers.map { worker in
            let key = worker.key ?? WorkerTab.firstKey
            let opens = worker.session.map { Opens.tab(task: task.id, sessionId: $0.sessionId) } ?? .nothing
            if worker.isOpening { return TabLine(key: key, agent: worker.agent, line: OperatorLine("opening"), status: .working, opens: .nothing) }
            switch worker.session?.state {
            case nil: return TabLine(key: key, agent: worker.agent, line: OperatorLine("closed"), status: nil, opens: .nothing)
            case .working?: return TabLine(key: key, agent: worker.agent, line: OperatorLine("at work"), status: .working, opens: opens)
            case .needsInput?:
                return TabLine(key: key, agent: worker.agent, line: OperatorLine("waiting on you", look: .needsYou), status: .needsInput, opens: opens)
            case .idle?, .done?:
                // Its turn ended with work running in the background, which wakes it again.
                let background = worker.background
                guard background.isEmpty else {
                    return TabLine(key: key, agent: worker.agent,
                                   line: OperatorLine("in background", tooltip: "Running in the background: " + background.joined(separator: ", ")),
                                   status: .background, opens: opens)
                }
                return TabLine(key: key, agent: worker.agent, line: OperatorLine("turn ended"), status: .idle, opens: opens)
            }
        }
    }

    /// The column a task's state puts it in. A blocked task stays where it was: In progress once it has
    /// started, Todo while it has not. In review is Review's, or In progress on a board with no Review.
    private static func column(of operated: OperatedTask, hasReview: Bool) -> Column {
        switch operated.state {
        case .planned, .queued: return .todo
        case .blocked: return operated.started ? .inProgress : .todo
        case .working, .failed: return .inProgress
        case .inReview: return hasReview ? .review : .inProgress
        case .accepted: return operated.isFinished ? .done : (hasReview && operated.peopleReview?.ended == false ? .review : .inProgress)
        case .noChange, .published, .stopped: return .done
        }
    }

    /// What resolves the card's request, by its kind (the one its line says), else its task's window once
    /// it has started. A finished task's leftover request asks nothing, as on its line.
    private static func opens(_ task: TaskItem, _ operated: OperatedTask, requests: [BroadcastRequest]) -> Opens {
        var kind: BroadcastRequest.Kind?
        if !operated.takenOver, !operated.isFinished {
            // A question the Operator asks about it is the Operator's row's, as on its line.
            kind = OperatorLine.first(requests.filter { $0.runId == operated.runId && $0.taskId == task.id && $0.kind != .question })?.kind
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

    /// `Codex · gpt-5.5 · high`, and the Operator's reason on the line under it. A Claude worker that says it runs another
    /// model or effort than planned (`live`, `LiveModel.differs`) adds `Now on claude-opus-5-5 · high` under them.
    private static func modelTooltip(_ task: TaskItem, _ operated: OperatedTask, live: LiveModel?) -> String? {
        guard !task.model.isEmpty else { return nil }
        let effort = task.reasoning.flatMap { $0.isEmpty ? nil : $0 }
        var lines = [([SidebarModel.agentName(task.agent), task.model] + [effort].compactMap { $0 }).joined(separator: " · ")]
        if let reason = operated.modelReason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty { lines.append(reason) }
        if let live, live.differs(fromModel: task.model, reasoning: effort) {
            lines.append("Now on " + ([live.model] + [live.reasoning].compactMap { $0 }).joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
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
