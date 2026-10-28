import Foundation

/// The broadcast's board, the sheet its row opens (spec §4, §4.2, §13), as a value: decided here, apart
/// from the app's `BroadcastBoardSheet`, so each moment is tested without drawing it.
///
/// The header restates the brief: the title, a band line with the broadcast's own status line
/// (`OperatorLine.broadcast`) and `· 2 of 8 done` after it, then the Asked line. A broadcast set up with the Agents, Task
/// and Done steps (broadcast setup v2) puts its goal on the Asked line and what every task follows on an Each task line
/// under it; its band counts the goal's rounds while it is checked, and once ended says how the goal went and how much
/// was left for you. The board is the plan: Todo · In progress · Review · Done, Review only while the broadcast's tasks
/// go into people's review (`TaskPublisher.Context.reviews`) or, set up with the Task step, its review prompt is written,
/// each task's card in the column its state puts it in, in the plan's order, and once every task is done they all sit
/// in Done, beside the cards of the tasks closed at the broadcast's end, drawn from their records.
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
        /// Its model and reasoning, under its key (`claude-opus-5-5 · High`); nil on a legacy broadcast's board.
        public var combination: String?
        public var id: String { key }
        public var isClosed: Bool { status == nil }

        public init(key: String, agent: AgentKind, line: OperatorLine, status: TaskStatus?, opens: Opens, combination: String? = nil) {
            self.key = key; self.agent = agent; self.line = line; self.status = status; self.opens = opens
            self.combination = combination
        }
    }

    /// A running card's end line (17A): `ends at` and its end, whose menu offers the four ends, the current one ticked.
    public struct EndLine: Equatable, Sendable {
        public var current: TaskEnd
        /// The ends the menu lets you pick, in `TaskEnd`'s order: Merge and Local merge only while the Merge slice is on.
        public var selectable: [TaskEnd]
        public init(current: TaskEnd, selectable: [TaskEnd]) { self.current = current; self.selectable = selectable }
    }

    /// Your answer to a task out of its review's fix rounds (`OperatorRun.fixRoundsQuestion(on:)`), from its card:
    /// each wakes the Operator with it, and the Operator resolves the question. Its question keeps the case's name
    /// (`OperatorQuestion.answeredOnCard`), so its words can change.
    public enum FixRoundsAnswer: String, CaseIterable, Sendable {
        case oneMoreRound, acceptAsItIs

        /// Its link on the card.
        public var title: String {
            switch self {
            case .oneMoreRound: "One More Round"
            case .acceptAsItIs: "Accept As It Is"
            }
        }

        /// As the Operator's wake line says it: `You answered cart-drawer’s fix rounds: one more round`.
        public var words: String {
            switch self {
            case .oneMoreRound: "one more round"
            case .acceptAsItIs: "accept it as it is"
            }
        }

        public func wakeReason(key: String) -> String { "You answered \(key)’s fix rounds: \(words)" }
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

    /// Each agent's model labels by model id, as Settings › Agents lists them: what a card names a model by.
    public typealias ModelLabels = [AgentKind: [String: String]]

    /// A task out of its review's fix rounds and asked about them (16): the answers' links, under the last verdict's
    /// counts when one was recorded, or what you answered once you did (`OperatorQuestion.answeredOnCard`).
    public struct FixRounds: Equatable, Sendable {
        public var counts: String?
        public var answered: FixRoundsAnswer?
        public init(counts: String?, answered: FixRoundsAnswer? = nil) { self.counts = counts; self.answered = answered }
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
        /// Its first worker's model and reasoning (14A), `Opus 5.5 · High`, while it has one worker tab; nil on a legacy
        /// broadcast's board, where the tooltip alone says it.
        public var combination: String? = nil
        /// Its end line while it has not finished and is not yours; nil once it has, on a legacy broadcast's board, and on
        /// the Shelf's.
        public var end: EndLine? = nil
        /// Out of its review's fix rounds and asked about them, while it is not yours.
        public var fixRounds: FixRounds? = nil
        /// Under its rule: why the closing kept its worktree once it ran (`OperatedTask.keptReason`), or while it is due what
        /// it waits for (`closingWait`); nil while neither is recorded.
        public var notice: String? = nil
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
    /// The Asked line's parts: the prompt, then the Review and the Done when a legacy broadcast has them, or the Goal.
    public var clauses: [Clause]
    /// What every task follows, the line under it (15A): the review prompt quoted, its end and its closing; nil for a
    /// legacy broadcast.
    public var eachTask: Clause? = nil
    /// How the goal went, once checked: the Summary's.
    public var goalOutcome: GoalOutcome? = nil
    /// The board's columns, Review left out unless its tasks go into people's review or, set up with the Task step, it
    /// has a review prompt.
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

    /// The Each task line whole, as its tooltip says it.
    public var eachTaskWhole: String { eachTask.map { "\($0.label) \($0.text)" } ?? "" }

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
    /// Claude worker runs now (`liveModels(of:state:sessions:)`), which the cards' tooltips say; `modelLabels` the names
    /// the cards give the models, a model with none named by its id.
    public static func make(run: OperatorRun, state: AppState, acting: OperatorActs, requests: [BroadcastRequest],
                            sessions: [SessionInfo] = [], liveModels: [UUID: LiveModel] = [:],
                            modelLabels: ModelLabels = [:]) -> BroadcastBoard {
        build(run: run, state: state, acting: acting, requests: requests, sessions: sessions, liveModels: liveModels,
              modelLabels: modelLabels, keepsHanded: false)
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
                              sessions: [SessionInfo], liveModels: [UUID: LiveModel], modelLabels: ModelLabels,
                              keepsHanded: Bool) -> BroadcastBoard {
        let tasks = state.tasks(inRun: run.id)
        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projects = run.projectIds.compactMap(state.project(id:))
        let names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        // People's review, or a set-up broadcast's review prompt: an agent review's tabs need no slice.
        let hasReview = TaskPublisher.Context.reviews(run)
            || run.taskSettings.map { OperatorCommand.said($0.review) != nil } == true

        // A task you stopped is no longer the broadcast's work: it is on no column. One End handed you stays In
        // progress on the Shelf's board, taken over, as it was when the broadcast ended.
        let cards = tasks.compactMap { task -> (Column, Card, AgentKind)? in
            guard let operated = task.operated else { return nil }
            let handed = keepsHanded && Self.handedOnEnd(operated)
            guard operated.state != .stopped || handed else { return nil }
            let card = Self.card(task, operated, run: run, acting: acting.tasks[task.id], requests: requests, tasks: byId, sessions: sessions,
                                 live: liveModels[task.id], turn: acting.turns[task.id], labels: modelLabels,
                                 project: projects.count > 1 ? names[task.projectId] : nil)
            // A set-up broadcast's task is in review while one of its review tabs is open.
            let reviewing = run.taskSettings != nil && OperatorLine.isInReview(operated, tabs: task.workerTabs(in: sessions))
            return (handed ? .inProgress : Self.column(of: operated, hasReview: hasReview, reviewing: reviewing), card, task.agent)
        }
        let removed = Self.removed(of: run, tasks: tasks).map { record in
            (Column.done, Self.card(record, labels: modelLabels, project: projects.count > 1 ? names[record.project] : nil), record.agent)
        }
        let columns = Column.allCases.filter { $0 != .review || hasReview }.map { column in
            // The closed ones first: the closing took them as they finished, before what finished since.
            Lane(column: column, cards: (removed + cards).filter { $0.0 == column }.map(\.1),
                 empty: Self.empty(column, planned: !tasks.isEmpty || !removed.isEmpty))
        }
        let band = OperatorLine.broadcast(run, tasks: tasks, acting: acting.broadcast(run.id), requests: requests,
                                          ready: SidebarModel.readyForAcceptance(tasks, sessions: sessions))
        return BroadcastBoard(
            runId: run.id, title: run.name, band: band,
            progress: progress(of: run, tasks: tasks, band: band, keepsHanded: keepsHanded),
            clauses: [Clause(label: "Asked", text: oneLine(run.prompt))]
                + [("Review", run.review), ("Done", run.done), ("Goal", run.goal?.text)].compactMap { label, text in
                    text.map(oneLine).flatMap { $0.isEmpty ? nil : Clause(label: label, text: $0) }
                },
            eachTask: run.taskSettings.map(eachTask), goalOutcome: run.goalOutcome,
            columns: columns,
            isPaused: run.isPaused,
            isComplete: run.state == .complete, summary: RunSummary(run), leftForYou: run.leftForYou, snags: run.snags)
    }

    /// The Each task line: the review prompt quoted when there is one, `ends at draft MR`, then `closed at the end`
    /// while finished tasks are closed.
    private static func eachTask(_ settings: TaskSettings) -> Clause {
        let review = settings.review.map(oneLine).flatMap { $0.isEmpty ? nil : "“\($0)”" }
        let parts = [review, "ends at " + settings.end.displayName, settings.closeWhenDone ? "closed at the end" : nil]
        return Clause(label: "Each task", text: parts.compactMap { $0 }.joined(separator: " · "))
    }

    /// The board of an ended `run` for the Shelf: every task it drove, the live ones and those archived since, in the
    /// order they were created (the state's order where that ties), and no card a button, no worker tab listed, no end to
    /// change, nothing paused. Nothing is live: no acts, no requests, no sessions. What End handed you, mid-flight, stays
    /// In progress reading `taken over` and counts towards the total, not as done: a broadcast ended at 2 of 8 says so.
    /// Its cards name each model by `modelLabels`, as the live board's do.
    public static func shelved(run: OperatorRun, state: AppState, modelLabels: ModelLabels = [:]) -> BroadcastBoard {
        var all = state
        let driven = state.tasks(inRun: run.id) + state.archive.map(\.task).filter { $0.operated?.runId == run.id }
        all.tasks = driven.enumerated().sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }.map(\.element)
        var board = build(run: run, state: all, acting: .none, requests: [], sessions: [], liveModels: [:], modelLabels: modelLabels, keepsHanded: true)
        board.columns = board.columns.map { lane in
            var lane = lane
            lane.cards = lane.cards.map { card in
                var card = card
                card.opens = .nothing
                card.tabs = []
                card.end = nil
                return card
            }
            return lane
        }
        board.isPaused = false
        board.isShelved = true
        return board
    }

    /// `2 of 8 done`, once the first plan is in Todo: the finished tasks of those not stopped, as the board's
    /// band says it. While the band says the goal is being checked (`OperatorLine.checkingTheGoal`) after an extra
    /// round, the extra rounds used and how many there are, `· round 1 of 2`; ended with the goal checked, how much was
    /// left for you, `· 2 left for you`.
    static func progress(of run: OperatorRun, tasks: [TaskItem], band: OperatorLine? = nil, keepsHanded: Bool = false) -> String? {
        guard let count = count(of: run, tasks: tasks, keepsHanded: keepsHanded) else { return nil }
        var parts = [count + " done"]
        // The first check follows the original plan, so it has no round.
        if band == .checkingTheGoal, run.roundsUsed > 0, let goal = run.goal { parts.append("round \(run.roundsUsed) of \(goal.extraRounds)") }
        if run.hasEnded, run.goalOutcome != nil, !run.leftForYou.isEmpty { parts.append("\(run.leftForYou.count) left for you") }
        return parts.joined(separator: " · ")
    }

    /// `2 of 8`, the progress as the broadcast's header in the sidebar says it; nil until the first plan is
    /// in Todo. A stopped task is not counted, unless `keepsHanded` and End handed it to you.
    static func count(of run: OperatorRun, tasks: [TaskItem], keepsHanded: Bool = false) -> String? {
        guard run.firstPlanSize != nil else { return nil }
        let counted = tasks.filter { task in
            guard let operated = task.operated, operated.runId == run.id else { return false }
            return operated.state != .stopped || (keepsHanded && handedOnEnd(operated))
        }
        // A handed task is stopped, which `isFinished` counts as an end: it was not done. A closed one was.
        let done = counted.filter { $0.operated.map { $0.isFinished && !handedOnEnd($0) } ?? false }.count
        let removed = removed(of: run, tasks: tasks).count
        return "\(done + removed) of \(counted.count + removed)"
    }

    /// The records of `run`'s tasks closed at its end whose rows are gone: a row still there is its own card.
    private static func removed(of run: OperatorRun, tasks: [TaskItem]) -> [FinishedTaskRecord] {
        let rows = Set(tasks.map(\.id))
        return run.finished.filter { !rows.contains($0.task) }
    }

    /// A task End handed you while it was in flight: stopped, and yours (`OperatorController.end`).
    private static func handedOnEnd(_ operated: OperatedTask) -> Bool { operated.state == .stopped && operated.takenOver }

    // MARK: - A card

    private static func card(_ task: TaskItem, _ operated: OperatedTask, run: OperatorRun, acting: OperatorAct?,
                             requests: [BroadcastRequest], tasks: [UUID: TaskItem], sessions: [SessionInfo], live: LiveModel?,
                             turn: WorkerTurn.Ending?, labels: ModelLabels, project: String?) -> Card {
        let setUp = run.taskSettings != nil, takenOver = operated.takenOver
        let closes = setUp && run.taskSettings?.closeWhenDone == true && operated.reachedItsEnd
        let kept = closes && closingRan(run)
        // Asked about its fix rounds; a request of its own (a prompt, a block) is said first, as every request is.
        let fixRounds = setUp && !operated.isFinished && !takenOver ? run.fixRoundsQuestion(on: task.id) : nil
        let asks = requests.contains { $0.runId == run.id && $0.taskId == task.id && $0.kind != .question }
        let line: OperatorLine? = if kept {
            // What it ended at without its detail, `draft MR · worktree kept`, so the line fits; why, under its rule.
            OperatorLine((OperatorLine.ending(of: operated)?.components(separatedBy: " · ").first ?? "done") + " · worktree kept", look: .ended)
        } else if let fixRounds, !asks {
            OperatorLine("out of fix rounds", look: .needsYou, tooltip: fixRounds.text)
        } else {
            OperatorLine.task(task, run: run, acting: acting, requests: requests, tasks: tasks, sessions: sessions, turn: turn)
        }
        let mr: (reference: String, host: CodeHost, title: String?)? = task.mr.map { ($0.reference, $0.host, $0.title) }
            ?? operated.publication.flatMap { publication in
                publication.mergeRequestNumber.map { number in
                    let host = CodeHost(webURL: publication.mergeRequestURL ?? "")
                    return (host.reference(number), host, nil)
                }
            }
        let tabs = tabs(of: task, sessions: sessions, labels: setUp ? labels : nil)
        return Card(id: task.id, title: task.title, agent: task.agent,
                    ticket: task.jira?.key, ticketSummary: task.jira?.summary,
                    mr: mr?.reference, mrHost: mr?.host, mrTitle: mr?.title, project: project,
                    line: takenOver ? nil : line, takenOver: takenOver,
                    needsYou: !takenOver && line?.look == .needsYou,
                    opens: opens(task, operated, requests: requests),
                    modelTooltip: modelTooltip(task, operated, live: live), result: OperatorLine.ending(of: operated),
                    tabs: tabs,
                    mergeRefusal: takenOver || operated.isFinished || (setUp && !operated.end.merges) ? nil : operated.publication?.mergeRefusal,
                    combination: setUp && tabs.isEmpty ? combination(task.agent, task.model, task.reasoning, labels: labels) : nil,
                    end: setUp && !operated.isFinished && !takenOver
                        ? EndLine(current: operated.end, selectable: TaskEnd.allCases.filter { TaskEndChange.isSelectable($0, in: run) }) : nil,
                    fixRounds: fixRounds.map { question in
                        FixRounds(counts: operated.reviewVerdicts.last.map(counts),
                                  answered: question.answeredOnCard.flatMap(FixRoundsAnswer.init(rawValue:)))
                    },
                    notice: kept ? operated.keptReason : closes && run.closingIsDue ? operated.closingWait?.text : nil)
    }

    /// Whether the closing has run since the broadcast last completed or ended (`closedAt`): a task that reached its
    /// end then and still has its row was kept. Once a new plan reopens a complete broadcast, its completion is cleared,
    /// and what finishes after is the next closing's to look at.
    private static func closingRan(_ run: OperatorRun) -> Bool {
        guard let closed = run.closedAt, let settled = [run.completedAt, run.endedAt].compactMap({ $0 }).max() else { return false }
        return closed >= settled
    }

    /// The card of a task closed at the broadcast's end, from its record: the title, agent, ticket and combination it
    /// had, its line as it read with `· removed` after it, and nothing to open.
    private static func card(_ record: FinishedTaskRecord, labels: ModelLabels, project: String?) -> Card {
        let effort = record.reasoning.flatMap { $0.isEmpty ? nil : $0 }
        return Card(id: record.task, title: record.title, agent: record.agent, ticket: record.ticket, ticketSummary: nil,
                    mr: nil, mrHost: nil, mrTitle: nil, project: project,
                    line: OperatorLine(record.result + " · removed", look: .ended), takenOver: false, needsYou: false, opens: .nothing,
                    modelTooltip: modelLine(record.agent, record.model, effort), result: record.result,
                    combination: combination(record.agent, record.model, record.reasoning, labels: labels))
    }

    /// `agent`'s model and its reasoning as a card says them, `Opus 5.5 · High`: the model by its label in `labels`, or by
    /// its id when none is known. Nil with no model.
    static func combination(_ agent: AgentKind, _ model: String, _ reasoning: String?, labels: ModelLabels) -> String? {
        guard !model.isEmpty else { return nil }
        let name = labels[agent]?[model] ?? model
        return ([name] + [reasoning.flatMap { $0.isEmpty ? nil : $0.capitalized }].compactMap { $0 }).joined(separator: " · ")
    }

    /// What a card out of fix rounds says under its rule, from the last verdict: `3 rounds of fixes, and the last review,
    /// of 4f2a91c, still found 1 Important.`, its findings listed by weight, or `didn’t pass.` with none counted.
    static func counts(of verdict: ReviewVerdict) -> String {
        let rounds = verdict.round
        let found = [("Critical", verdict.critical), ("Important", verdict.important), ("Minor", verdict.minor)]
            .filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }
        let lead = "\(rounds) \(rounds == 1 ? "round" : "rounds") of fixes, and the last review, of \(verdict.sha.prefix(7)), "
        return lead + (found.isEmpty ? "didn’t pass." : "still found " + found.sentenceList + ".")
    }

    /// A card's tab lines, as `sessions` list its worker tabs; none for a task with one. With `labels`, each tab's model
    /// and reasoning under its key.
    private static func tabs(of task: TaskItem, sessions: [SessionInfo], labels: ModelLabels?) -> [TabLine] {
        let workers = task.workerTabs(in: sessions)
        guard workers.count > 1 else { return [] }
        let extra = Dictionary((task.operated?.extraTabs ?? []).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return workers.map { worker in
            var tab = tabLine(of: worker, task: task.id)
            if let labels {
                tab.combination = worker.key.map { extra[$0].flatMap { combination($0.agent, $0.model, $0.reasoning, labels: labels) } }
                    ?? combination(task.agent, task.model, task.reasoning, labels: labels)
            }
            return tab
        }
    }

    /// One worker tab's line: what it does and its mark.
    private static func tabLine(of worker: WorkerTab, task: UUID) -> TabLine {
        let key = worker.key ?? WorkerTab.firstKey
        let opens = worker.session.map { Opens.tab(task: task, sessionId: $0.sessionId) } ?? .nothing
        if worker.isOpening { return TabLine(key: key, agent: worker.agent, line: OperatorLine("opening"), status: .working, opens: .nothing) }
        if let tests = worker.session?.testActivity, worker.session?.state != .needsInput,
           tests.isActive || worker.session?.state.turnEnded == true {
            return TabLine(key: key, agent: worker.agent, line: tests.statusLine,
                           status: tests.isActive ? .background : .idle, opens: opens)
        }
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

    /// The column a task's state puts it in. A blocked task stays where it was: In progress once it has
    /// started, Todo while it has not. In review is Review's, or In progress on a board with no Review; so is a working
    /// task `reviewing` in a review tab.
    private static func column(of operated: OperatedTask, hasReview: Bool, reviewing: Bool) -> Column {
        switch operated.state {
        case .planned, .queued: return .todo
        case .blocked: return operated.started ? .inProgress : .todo
        case .working: return reviewing && hasReview ? .review : .inProgress
        case .failed: return .inProgress
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

    /// `Codex · gpt-5.5 · high`, and the Operator's reason on the line under it. A Claude worker that says it runs another
    /// model or effort than planned (`live`, `LiveModel.differs`) adds `Now on claude-opus-5-5 · high` under them.
    private static func modelTooltip(_ task: TaskItem, _ operated: OperatedTask, live: LiveModel?) -> String? {
        guard !task.model.isEmpty else { return nil }
        let effort = task.reasoning.flatMap { $0.isEmpty ? nil : $0 }
        var lines = [modelLine(task.agent, task.model, effort)]
        if let reason = operated.modelReason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty { lines.append(reason) }
        if let live, live.differs(fromModel: task.model, reasoning: effort) {
            lines.append("Now on " + ([live.model] + [live.reasoning].compactMap { $0 }).joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    /// The tooltip's first line, `Codex · gpt-5.5 · high`.
    private static func modelLine(_ agent: AgentKind, _ model: String, _ effort: String?) -> String {
        ([SidebarModel.agentName(agent), model] + [effort].compactMap { $0 }).joined(separator: " · ")
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

public extension OperatorRun {
    /// The open question asking you about `task`'s fix rounds (`OperatorQuestion.fixRounds`), which its card answers.
    func fixRoundsQuestion(on task: UUID) -> OperatorQuestion? {
        questions.first { $0.task == task && $0.about == OperatorQuestion.fixRounds && $0.resolution == nil }
    }
}
