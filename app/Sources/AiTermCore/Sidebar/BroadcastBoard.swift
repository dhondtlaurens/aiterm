import Foundation

/// The broadcast's sheet, which its row opens (spec §4, §4.2, §13; rebuilt 14 Nov 2026), as a value: decided here,
/// apart from the app's `BroadcastBoardSheet`, so each moment is tested without drawing it.
///
/// The header is the title, a band line with the broadcast's own status line (`OperatorLine.broadcast`) and
/// `· 2 of 8 done` after it, and one line of the brief, Asked, the whole of it (`brief`: Asked, the Goal, Each task) in
/// its tooltip. A broadcast set up with the Agents, Task and Done steps counts the goal's rounds on its band while it
/// is checked, and once ended says how the goal went and how much was left for you.
///
/// The Tasks tab reads, in this order: Waiting on you, every open question for the person, one shown at a time
/// (`waiting`); the Operator's summary once there is one or a reason there is none (`summary`, `goalOutcome`); what it
/// left for you, from the first item (`leftForYou`); the tasks, each a `Card` under its stage (`listed`: In progress,
/// Review, Todo, Done, a stage with no task left out); and what the Operator worked around in AiTerm (`snags`).
/// Review is a stage only while the broadcast's tasks go into people's review (`TaskPublisher.Context.reviews`) or, set
/// up with the Task step, its review prompt is written. Once every task is done they all sit in Done, beside the tasks
/// closed at the broadcast's end, drawn from their records. An ended broadcast read from the Shelf is a `shelved`
/// board, read-only.
public struct BroadcastBoard: Equatable, Sendable {
    /// Where a task is in the plan, in the plan's own order.
    public enum Stage: String, CaseIterable, Sendable {
        case todo, inProgress, review, done

        /// The order the sheet lists them in: what is at work first, then what waits to start, then what is done.
        public static let listed: [Stage] = [.inProgress, .review, .todo, .done]

        /// Its head, a `SidebarHeading`, which draws it as written: sentence case.
        public var title: String {
            switch self {
            case .todo: "Todo"
            case .inProgress: "In progress"
            case .review: "Review"
            case .done: "Done"
            }
        }
    }

    /// Where a task's click goes once the sheet is closed: what resolves its request, or its task.
    public enum Opens: Equatable, Sendable {
        /// An agent's permission prompt, or a started task with nothing asked: the task's window.
        case taskWindow(UUID)
        /// A blocked task: the Operator's window, where it is answered.
        case operatorWindow
        /// A problem AiTerm hit: the sidebar banner's Notice already shows the issue, with its recovery.
        case sidebarBanner(issue: String)
        /// A worker's prompt, from its block under Waiting on you: its own tab, by its key (`WorkerTab.firstKey` for the
        /// first worker), brought forward, or the task's window when that tab isn't listed.
        case prompt(task: UUID, tab: String)
        /// A Todo task that has not started: its row is not a button.
        case nothing
    }

    /// An unfinished task's end, which its row's menu changes: the four ends, the current one ticked.
    public struct EndLine: Equatable, Sendable {
        public var current: TaskEnd
        /// The ends the menu lets you pick, in `TaskEnd`'s order: Merge and Local merge only while the Merge slice is on.
        public var selectable: [TaskEnd]
        public init(current: TaskEnd, selectable: [TaskEnd]) { self.current = current; self.selectable = selectable }
    }

    /// Your answer to a task out of its review's fix rounds, which its question keeps (`AiTermCore.FixRoundsAnswer`).
    public typealias FixRoundsAnswer = AiTermCore.FixRoundsAnswer

    /// What a task's Claude worker says it runs now (`SessionInfo.liveModel`, `.liveReasoning`), which its row's tooltip
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

    /// Each agent's model labels by model id, as Settings › Agents lists them: what a row's tooltip names a model by.
    public typealias ModelLabels = [AgentKind: [String: String]]

    /// One question in Waiting on you: every open question addressed to the person, whoever asks, oldest first, one
    /// shown at a time. Its task (ticket and title, or `The broadcast`), who asks or where it waits and its age head
    /// its block; then the question; one line of context when it has one (`why`, `note`); then how it is answered:
    /// here, by a choice or in words, or there, by the one button that opens where it waits.
    public struct ListedQuestion: Equatable, Identifiable, Sendable {
        /// How it is answered.
        public enum Answer: Equatable, Sendable {
            /// In its block: its choices as buttons, then any other answer in a field, unless `field` is false (fix
            /// rounds, whose answers are fixed).
            case here(choices: [String], field: Bool)
            /// A worker's prompt: Open its window, its own tab raised. AiTerm never types a permission.
            case window(task: UUID, tab: String)
            /// A command the Oracle stopped: Open the Operator's chat, where it is allowed (22 Oct, trust over a button).
            case chat
        }

        public var key: String
        public var task: UUID?
        public var ticket: String?
        /// The task's title, or `The broadcast` for a question on no task.
        public var title: String
        public var askedAt: Date
        /// Who asks, or where it waits: `The Operator asks`, `AiTerm asks`, `Waits in its worker’s window`.
        public var from: String
        public var text: String
        public var answer: Answer
        /// What the person answered in AiTerm, and when when it is known: the block then says so until the Operator
        /// resolves the question.
        public var answered: String?
        public var answeredAt: Date?
        /// For a worker's question the Operator relayed, why it reached you, in one line (`QuestionStep`s summed up), and
        /// the whole discussion its Read the discussion opens: the Oracle's rounds and the Operator's replies. Nil for
        /// one relayed straight, and for any other question.
        public var why: String? = nil
        public var discussion: [QuestionStep]? = nil
        /// For a fix-rounds question, what the last review still found (`BroadcastBoard.counts(of:)`); nil for the rest.
        public var note: String? = nil
        public var id: String { key }

        public init(key: String, task: UUID?, ticket: String?, title: String, askedAt: Date, from: String, text: String,
                    answer: Answer, answered: String? = nil, answeredAt: Date? = nil, why: String? = nil,
                    discussion: [QuestionStep]? = nil, note: String? = nil) {
            self.key = key; self.task = task; self.ticket = ticket; self.title = title; self.askedAt = askedAt; self.from = from
            self.text = text; self.answer = answer; self.answered = answered; self.answeredAt = answeredAt
            self.why = why; self.discussion = discussion; self.note = note
        }

        /// Whether it is answered in its block: a row of its task then shows it instead of opening a window.
        public var isAnsweredHere: Bool { if case .here = answer { true } else { false } }

        /// What an answered block says: `You answered “Drop it for admins” 2 min ago. Waiting for the Operator to take
        /// it.`, without the age when AiTerm didn't record when (an answer to fix rounds).
        public func answeredLine(now: Date) -> String? {
            guard let answered else { return nil }
            let when = answeredAt.map { " " + BroadcastBoard.age(since: $0, now: now) + " ago" } ?? ""
            return "You answered “\(answered)”\(when). Waiting for the Operator to take it."
        }
    }

    /// How long ago `date` was, as a block's head says it: `1 min`, `24 min`, `2 h`, `3 d`, never less than a minute.
    public static func age(since date: Date, now: Date) -> String {
        let minutes = max(1, Int(now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 24 * 60 { return "\(minutes / 60) h" }
        return "\(minutes / (24 * 60)) d"
    }

    /// One task on the sheet, a row under its stage: the sidebar's driven-task row (`SidebarModel.RowFacts`) with its
    /// ticket and request trailing.
    public struct Card: Equatable, Identifiable, Sendable {
        /// The task's id.
        public var id: UUID
        public var title: String
        /// Its tabs' agents as its sidebar row has them; its planned agent while it has no tab, started or not (spec §15.4).
        public var avatars: AvatarGroup
        /// Its row's status, and whether the pause sign stands in for its mark (`TaskRow.status`, `.queued`, `.paused`).
        public var status: TaskStatus
        public var queued: Bool = false
        public var paused: Bool = false
        /// Its Jira key, and the ticket's summary for the badge's tooltip.
        public var ticket: String?
        public var ticketSummary: String?
        /// Its merge or pull request, as its host writes it (`!418`), the host, and the request's title.
        public var mr: String?
        public var mrHost: CodeHost?
        public var mrTitle: String?
        /// Its project, only when the broadcast spans more than one: the tooltip's first line.
        public var project: String?
        /// The task's status line (`OperatorLine.task`); nil for a task you took over.
        public var line: OperatorLine?
        /// You took it over: the row reads `taken over` with no badge until you Hand Back.
        public var takenOver: Bool
        /// Its line asks for you: a prompt, a question that holds it, a block, its fix rounds.
        public var needsYou: Bool
        public var opens: Opens
        /// The model the Operator chose, by its label when Settings has one, and its one-line reason (spec §15.4):
        /// `Codex · gpt-5.5 · high`, then the reason on a line of its own.
        public var modelTooltip: String?
        /// What a finished task ended at (`merged · 9b3e07d`).
        public var result: String?
        /// The Oracle’s reason for refusing a merge, separate from the task’s status.
        public var mergeRefusal: String? = nil
        /// The task's end while it is unfinished and owned by the Operator.
        public var end: EndLine? = nil
        /// Whether its menu's Operator items include Stop Task… (`OperatedTask.isStoppable`); nil where it has none of
        /// them: a shelved board's row, and a task closed and removed. Take Over or Hand Back follows `takenOver`.
        public var stoppable: Bool? = nil
        /// Why the closing kept its worktree once it ran (`OperatedTask.keptReason`), or while it is due what it waits for
        /// (`closingWait`); nil while neither is recorded.
        public var notice: String? = nil
        /// What its worker asks the Operator and the Operator hasn't answered nor relayed (`OperatorActs.asks`); nil
        /// while it is yours, or once relayed: the question is yours then, under Waiting on you.
        public var workerAsks: String? = nil

        /// The one line a row may add under itself, for what the person has to act on or know: why its worktree was kept
        /// or what its closing waits for, else that the Oracle refused its merge.
        public var help: String? { notice ?? (mergeRefusal == nil ? nil : Card.mergeRefused) }
        /// What a row says under itself once the Oracle refused its merge; the reason is that line's tooltip.
        public static let mergeRefused = "merge refused by the Oracle"

        /// The row's tooltip: its project when the broadcast spans several, the model and why, and what its worker asks
        /// the Operator. Nil with none of them.
        public var tooltip: String? {
            let lines = [project, modelTooltip, workerAsks.map { "Its worker asks the Operator: \($0)" }].compactMap { $0 }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
    }

    /// A stage: its head and its cards.
    public struct Lane: Equatable, Identifiable, Sendable {
        public var stage: Stage
        public var cards: [Card]
        public var id: Stage { stage }
        public var title: String { stage.title }
    }

    /// One line of the sheet's header: `Asked`, `Goal` or `Each task`, then what it says.
    public struct Clause: Equatable, Sendable {
        public var label: String
        public var text: String
        public init(label: String, text: String) { self.label = label; self.text = text }

        /// The line whole, as its tooltip says it.
        public var whole: String { "\(label) \(text)" }
    }

    /// The sheet's tabs, in the order they are drawn.
    public enum Tab: CaseIterable, Sendable {
        case tasks, activity

        public var title: String {
            switch self {
            case .tasks: "Tasks"
            case .activity: "Activity"
            }
        }
    }

    public var runId: UUID
    public var title: String
    /// The broadcast's status line, the band's first part.
    public var band: OperatorLine
    /// `2 of 8 done`, after the band's status line; nil until the first plan is in Todo.
    public var progress: String?
    /// The broadcast prompt, then its goal when it has one.
    public var clauses: [Clause]
    /// What every task follows: its review prompt, end and closing settings.
    public var eachTask: Clause
    /// How the goal went, once checked: under the summary.
    public var goalOutcome: GoalOutcome? = nil
    /// The plan's stages in its own order, Review left out unless its tasks go into people's review or, set up with the
    /// Task step, it has a review prompt.
    public var stages: [Lane]
    /// Paused by you, or its Operator's window closed: the footer offers Resume Broadcast.
    public var isPaused: Bool
    /// Every task is done (the run is complete): the footer's End Broadcast, asking nothing.
    public var isComplete: Bool
    /// What the summary says (`RunSummary`).
    public var summary: RunSummary
    /// What the Operator left for you, as `leave_for_you` wrote it, listed from its first item.
    public var leftForYou: [String]
    /// What the Operator worked around in AiTerm, as `report_snag` recorded it: the Tasks tab's last list.
    public var snags: [OperatorSnag] = []
    /// An ended broadcast read from the Shelf: nothing on it acts, and the footer is Close alone.
    public var isShelved: Bool = false
    /// Waiting on you: every open question for the person, oldest first (`waiting(of:state:)`).
    public var waiting: [ListedQuestion] = []

    /// The brief's lines, one each: Asked, Goal, then Each task. The header draws the first; `brief` says them all.
    public var headerLines: [Clause] { clauses + [eachTask] }
    /// The whole brief, a line each: the header line's tooltip.
    public var brief: String { headerLines.map(\.whole).joined(separator: "\n") }

    /// The stages as the sheet lists them (`Stage.listed`), one with no task left out.
    public var listed: [Lane] {
        Stage.listed.compactMap { stage in stages.first { $0.stage == stage && !$0.cards.isEmpty } }
    }
    /// What the Tasks tab says in the stages' place while the broadcast has no task yet.
    public static let nothingPlanned = "Nothing planned yet."

    /// What a snag's Copy puts on the clipboard: the AiTerm task that fixes it, naming this broadcast.
    public func fixTask(_ snag: OperatorSnag) -> String { snag.fixTask(broadcast: title, runId: runId) }

    /// What Copy All puts on the clipboard: every snag's fix task in the order they were reported, a rule between
    /// each. Nil with fewer than two, where an item's own Copy is all there is.
    public var copyAll: String? {
        snags.count > 1 ? snags.map(fixTask).joined(separator: "\n\n---\n\n") : nil
    }

    /// The board of `run` as `state` has it. `acting` is what the Operator is doing now, as
    /// `OperatorController.acting` says it; `requests` are the broadcast's open requests (`OperatorRequests`);
    /// `sessions` the tabs as iTerm2 lists them, which the band reads as its row does, as of `now`; `liveModels` what each task's
    /// Claude worker runs now (`liveModels(of:state:sessions:)`), which the rows' tooltips say; `modelLabels` the names
    /// they give the models, a model with none named by its id. `pass` is the sidebar derivation's (`SidebarPass`),
    /// whose tabs the board reads instead of matching them again; without one it matches them as of `now`.
    public static func make(run: OperatorRun, state: AppState, acting: OperatorActs, requests: [BroadcastRequest],
                            sessions: [SessionInfo] = [], now: Date = Date(), pass: SidebarPass? = nil,
                            liveModels: [UUID: LiveModel] = [:], modelLabels: ModelLabels = [:]) -> BroadcastBoard {
        let pass = pass ?? SidebarPass(state: state, sessions: sessions, now: now, matching: state.tasks(inRun: run.id))
        return build(run: run, state: state, acting: acting, requests: requests, sessions: sessions, pass: pass, liveModels: liveModels,
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
                              sessions: [SessionInfo], pass: SidebarPass, liveModels: [UUID: LiveModel], modelLabels: ModelLabels,
                              keepsHanded: Bool) -> BroadcastBoard {
        let tasks = state.tasks(inRun: run.id)
        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projects = run.projectIds.compactMap(state.project(id:))
        let names = Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        // People's review or a task review prompt: agent review tabs need no slice.
        let hasReview = TaskPublisher.Context.reviews(run)
            || OperatorCommand.said(run.taskSettings.review) != nil

        // A task you stopped is no longer the broadcast's work: it is under no stage. One End handed you stays In
        // progress on the Shelf's board, taken over, as it was when the broadcast ended.
        let cards = tasks.compactMap { task -> (Stage, Card)? in
            guard let operated = task.operated else { return nil }
            let handed = keepsHanded && Self.handedOnEnd(operated)
            guard operated.state != .stopped || handed else { return nil }
            // Its tabs, matched once for the board as of the pass's time: its line, its row facts and its stage read them.
            let tabs = pass.tabs(of: task.id) ?? task.workerTabs(in: sessions, now: pass.now)
            var card = Self.card(task, operated, run: run, acting: acting.tasks[task.id], requests: requests, tasks: byId, sessions: sessions,
                                 tabs: tabs, now: pass.now, live: liveModels[task.id], turn: acting.turns[task.id], labels: modelLabels,
                                 project: projects.count > 1 ? names[task.projectId] : nil)
            // Relayed, it is a record of yours, a question under Waiting on you instead.
            let relayed = run.questions.contains { $0.task == task.id && $0.resolution == nil && $0.relayedFrom != nil }
            if !operated.takenOver, !relayed { card.workerAsks = acting.asks[task.id] }
            // A task is in review while one of its review tabs is open.
            let reviewing = OperatorLine.isInReview(operated, tabs: tabs.map(\.asListed))
            return (handed ? .inProgress : Self.stage(of: operated, hasReview: hasReview, reviewing: reviewing), card)
        }
        let removed = Self.removed(of: run, tasks: tasks).map { record in
            (Stage.done, Self.card(record, labels: modelLabels, project: projects.count > 1 ? names[record.project] : nil))
        }
        let stages = Stage.allCases.filter { $0 != .review || hasReview }.map { stage in
            // The closed ones first: the closing took them as they finished, before what finished since.
            Lane(stage: stage, cards: (removed + cards).filter { $0.0 == stage }.map(\.1))
        }
        let band = OperatorLine.broadcast(run, tasks: tasks, acting: acting.broadcast(run.id), requests: requests,
                                          ready: SidebarModel.readyForAcceptance(tasks, sessions: sessions, pass: pass))
        return BroadcastBoard(
            runId: run.id, title: run.name, band: band,
            progress: progress(of: run, tasks: tasks, band: band, keepsHanded: keepsHanded),
            clauses: [Clause(label: "Asked", text: oneLine(run.prompt))]
                + [("Goal", run.goal?.text)].compactMap { label, text in
                    text.map(oneLine).nonEmpty.map { Clause(label: label, text: $0) }
                },
            eachTask: eachTask(run.taskSettings), goalOutcome: run.goalOutcome,
            stages: stages,
            isPaused: run.isPaused,
            isComplete: run.state == .complete, summary: RunSummary(run), leftForYou: run.leftForYou, snags: run.snags,
            waiting: waiting(of: run, state: state))
    }

    /// Waiting on you: every open question of `run` addressed to the person, read from its questions themselves, so two
    /// tabs of a task prompting at once are two blocks (`OperatorRequests.open` says a task's prompts as one). What asks
    /// nothing is left out, as there: an ended run's, a task's you took over, and a finished task's that holds it. Oldest
    /// first, a tie in the order they were recorded.
    public static func waiting(of run: OperatorRun, state: AppState) -> [ListedQuestion] {
        guard !run.hasEnded else { return [] }
        let tasks = Dictionary(state.tasks(inRun: run.id).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let records = Dictionary(run.finished.map { ($0.task, $0) }, uniquingKeysWith: { first, _ in first })
        let listed = run.questions.enumerated().compactMap { offset, question -> (Int, ListedQuestion)? in
            guard question.resolution == nil else { return nil }
            let operated = question.task.flatMap { tasks[$0]?.operated }
            if let operated, operated.takenOver || (operated.isFinished && question.holdsTask) { return nil }
            let task = question.task.flatMap { tasks[$0] }
            let title = task?.title ?? question.task.flatMap { records[$0]?.title } ?? "The broadcast"
            let ticket = task?.jira?.key ?? question.task.flatMap { records[$0]?.ticket }
            return (offset, ListedQuestion(key: question.id, task: question.task, ticket: ticket, title: title, askedAt: question.askedAt,
                                           from: from(question), text: question.text, answer: answer(question),
                                           answered: question.answer, answeredAt: question.answeredHereAt,
                                           why: why(question.history), discussion: discussion(question.history),
                                           note: question.kind == .fixRounds ? operated?.reviewVerdicts.last.map(counts) : nil))
        }
        return listed.sorted { ($0.1.askedAt, $0.0) < ($1.1.askedAt, $1.0) }.map(\.1)
    }

    /// Who asks, or where a question answered there waits.
    private static func from(_ question: OperatorQuestion) -> String {
        if question.kind == .prompt {
            guard case .extra(let tab) = TabReference(question.tab) else { return "Waits in its worker’s window" }
            return "Waits in its \(tab) tab"
        }
        if question.kind == .gate { return "Waits in the Operator’s chat" }
        switch question.asker {
        case .aiterm: return "AiTerm asks"
        case .theOperator: return "The Operator asks"
        case .worker:
            let tab = question.relayedFrom.flatMap { TabReference($0).key }
            return (tab.map { "Its \($0) tab asks" } ?? "Its worker asks") + " · relayed by the Operator"
        }
    }

    /// The Oracle's part in a relay, after its rounds: nil when it had none.
    private static func discussion(_ history: [QuestionStep]?) -> [QuestionStep]? {
        let steps = (history ?? []).filter { $0.kind != .asked }
        return steps.isEmpty ? nil : steps
    }

    /// Why a relayed question reached you, in one line: the Oracle's rounds, or why it had none.
    static func why(_ history: [QuestionStep]?) -> String? {
        let steps = history ?? []
        if let unchallenged = steps.last(where: { $0.kind == .unchallenged }) { return "Unchallenged: \(unchallenged.text)" }
        let rounds = steps.compactMap { $0.kind == .oracle ? $0.round : nil }.max() ?? 0
        guard rounds > 0 else { return nil }
        let replied = steps.contains { $0.kind == .reply }
        let said = rounds == 1 ? "The Oracle looked at it once" : "The Oracle and the Operator took \(rounds) rounds"
        return said + (replied ? ", and the Operator kept it for you." : ", and agreed only you can answer it.")
    }

    /// How a question is answered: there, by one link, or here, with its choices and a field.
    private static func answer(_ question: OperatorQuestion) -> ListedQuestion.Answer {
        if question.kind == .prompt, let task = question.task {
            return .window(task: task, tab: TabReference(question.tab).name)
        }
        if question.kind == .gate { return .chat }
        if question.kind == .fixRounds { return .here(choices: FixRoundsAnswer.allCases.map(\.title), field: false) }
        return .here(choices: question.choices ?? [], field: true)
    }

    /// The Each task line: the review prompt quoted when there is one, `ends at draft MR`, then `closed at the end`
    /// while finished tasks are closed.
    private static func eachTask(_ settings: TaskSettings) -> Clause {
        let review = settings.review.map(oneLine).nonEmpty.map { "“\($0)”" }
        let parts = [review, "ends at " + settings.end.displayName, settings.closeWhenDone ? "closed at the end" : nil]
        return Clause(label: "Each task", text: parts.compactMap { $0 }.joined(separator: " · "))
    }

    /// The board of an ended `run` for the Shelf: every task it drove, the live ones and those archived since, in the
    /// order they were created (the state's order where that ties), and no row a button, no end to change, nothing
    /// paused. A finished task's line is what it ended at (`Card.result`). Nothing is live: no acts, no requests, no sessions. What End handed you, mid-flight, stays
    /// In progress reading `taken over` and counts towards the total, not as done: a broadcast ended at 2 of 8 says so.
    /// Its rows' tooltips name each model by `modelLabels`, as the live board's do.
    public static func shelved(run: OperatorRun, state: AppState, modelLabels: ModelLabels = [:]) -> BroadcastBoard {
        var all = state
        let driven = state.tasks(inRun: run.id) + state.archive.map(\.task).filter { $0.operated?.runId == run.id }
        all.tasks = driven.enumerated().sorted { ($0.element.createdAt, $0.offset) < ($1.element.createdAt, $1.offset) }.map(\.element)
        let pass = SidebarPass(state: all, sessions: [], now: Date(), matching: [])
        var board = build(run: run, state: all, acting: .none, requests: [], sessions: [], pass: pass, liveModels: [:], modelLabels: modelLabels,
                          keepsHanded: true)
        board.stages = board.stages.map { lane in
            var lane = lane
            lane.cards = lane.cards.map { card in
                var card = card
                card.opens = .nothing
                card.end = nil
                card.stoppable = nil
                // An ended broadcast's tasks have no Operator's line any more: a finished one says what it ended at, with
                // the check that line gives its row. One End handed you has neither: it reads taken over.
                if card.line == nil, !card.takenOver, let result = card.result { card.line = OperatorLine(result, look: .ended) }
                return card
            }
            return lane
        }
        board.isPaused = false
        board.isShelved = true
        board.waiting = []
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

    /// `2 of 8`, the progress as the OPERATOR heading in the sidebar says it; nil until the first plan is
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
                             requests: [BroadcastRequest], tasks: [UUID: TaskItem], sessions: [SessionInfo], tabs workers: [WorkerTab],
                             now: Date, live: LiveModel?,
                             turn: WorkerTurn.Ending?, labels: ModelLabels, project: String?) -> Card {
        let takenOver = operated.takenOver
        let closes = run.taskSettings.closeWhenDone == true && operated.reachedItsEnd
        let kept = closes && run.closingHasRun
        // Asked about its fix rounds; a request of its own (a prompt, a block) is said first, as every request is.
        let fixRounds = !operated.isFinished && !takenOver ? run.fixRoundsQuestion(on: task.id) : nil
        let asks = requests.contains { $0.runId == run.id && $0.taskId == task.id && $0.kind != .question }
        let line: OperatorLine? = if kept {
            // What it ended at without its detail, `draft MR · worktree kept`, so the line fits; why, under its rule.
            OperatorLine((OperatorLine.ending(of: operated)?.components(separatedBy: " · ").first ?? "done") + " · worktree kept", look: .ended)
        } else if let fixRounds, !asks {
            OperatorLine("out of fix rounds", look: .needsYou, tooltip: fixRounds.text)
        } else {
            OperatorLine.task(task, run: run, acting: acting, requests: requests, tasks: tasks, sessions: sessions, turn: turn, now: now,
                              tabs: workers)
        }
        let mr: (reference: String, host: CodeHost, title: String?)? = task.mr.map { ($0.reference, $0.host, $0.title) }
            ?? operated.publication.flatMap { publication in
                publication.mergeRequestNumber.map { number in
                    let host = CodeHost(webURL: publication.mergeRequestURL ?? "")
                    return (host.reference(number), host, nil)
                }
            }
        // Its row as the sidebar draws it, from its own tabs and the line it reads here; its planned agent while it has no tab.
        let own = sessions.filter { $0.taskUUID == task.id }
        let shown = takenOver ? nil : line
        let facts = SidebarModel.rowFacts(task, own: own, line: shown, run: run, matched: workers)
        return Card(id: task.id, title: task.title,
                    avatars: own.isEmpty ? AvatarGroup(marks: [task.agent.session], overflow: 0) : facts.avatars,
                    status: facts.status, queued: facts.queued, paused: facts.paused,
                    ticket: task.jira?.key, ticketSummary: task.jira?.summary,
                    mr: mr?.reference, mrHost: mr?.host, mrTitle: mr?.title, project: project,
                    line: shown, takenOver: takenOver,
                    needsYou: !takenOver && line?.look == .needsYou,
                    opens: opens(task, operated, requests: requests),
                    modelTooltip: modelTooltip(task, operated, live: live, labels: labels), result: OperatorLine.ending(of: operated),
                    mergeRefusal: takenOver || operated.isFinished || (!operated.end.merges) ? nil : operated.publication?.mergeRefusal,
                    end: !operated.isFinished && !takenOver
                        ? EndLine(current: operated.end, selectable: TaskEnd.allCases.filter { TaskEndChange.isSelectable($0, in: run) }) : nil,
                    stoppable: operated.isStoppable,
                    notice: kept ? operated.keptReason : closes && run.closingIsDue ? operated.closingWait?.text : nil)
    }

    /// The card of a task closed at the broadcast's end, from its record: the title, agent and ticket it had, its line
    /// as it read with `· removed` after it, the check its ended line gives it, and nothing to open.
    private static func card(_ record: FinishedTaskRecord, labels: ModelLabels, project: String?) -> Card {
        let effort = record.reasoning.nonEmpty
        return Card(id: record.task, title: record.title, avatars: AvatarGroup(marks: [record.agent.session], overflow: 0), status: .idle,
                    ticket: record.ticket, ticketSummary: nil, mr: nil, mrHost: nil, mrTitle: nil, project: project,
                    line: OperatorLine(record.result + " · removed", look: .ended), takenOver: false, needsYou: false, opens: .nothing,
                    modelTooltip: modelLine(record.agent, record.model, effort, labels: labels), result: record.result)
    }

    /// What a fix-rounds question says under itself (`ListedQuestion.note`), from the last verdict: `3 rounds of fixes, and the last review,
    /// of 4f2a91c, still found 1 Important.`, its findings listed by weight, or `didn’t pass.` with none counted.
    static func counts(of verdict: ReviewVerdict) -> String {
        let rounds = verdict.round
        let found = [("Critical", verdict.critical), ("Important", verdict.important), ("Minor", verdict.minor)]
            .filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }
        let lead = "\(rounds) \(rounds == 1 ? "round" : "rounds") of fixes, and the last review, of \(verdict.sha.prefix(7)), "
        return lead + (found.isEmpty ? "didn’t pass." : "still found " + found.sentenceList + ".")
    }

    /// The stage a task's state puts it in. A blocked task stays where it was: In progress once it has
    /// started, Todo while it has not. In review is Review's, or In progress on a board with no Review; so is a working
    /// task `reviewing` in a review tab.
    private static func stage(of operated: OperatedTask, hasReview: Bool, reviewing: Bool) -> Stage {
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

    /// What resolves the task's request, by its kind (the one its line says), else its task's window once
    /// it has started. A finished task's leftover request asks nothing, as on its line. A question answered in the sheet
    /// is shown there first: the sheet reads `waiting` before it opens anything (`BroadcastBoardSheet.shows`).
    private static func opens(_ task: TaskItem, _ operated: OperatedTask, requests: [BroadcastRequest]) -> Opens {
        var kind: BroadcastRequest.Kind?
        if !operated.takenOver, !operated.isFinished {
            kind = OperatorLine.first(requests.filter { $0.runId == operated.runId && $0.taskId == task.id && $0.holds })?.kind
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

    /// `Codex · gpt-5.5 · high`, the model by its label in `labels` when it has one, and the Operator's reason on the line
    /// under it. A Claude worker that says it runs another model or effort than planned (`live`, `LiveModel.differs`)
    /// adds `Now on claude-opus-5-5 · high` under them.
    private static func modelTooltip(_ task: TaskItem, _ operated: OperatedTask, live: LiveModel?, labels: ModelLabels) -> String? {
        guard !task.model.isEmpty else { return nil }
        let effort = task.reasoning.nonEmpty
        var lines = [modelLine(task.agent, task.model, effort, labels: labels)]
        if let reason = operated.modelReason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty { lines.append(reason) }
        if let live, live.differs(fromModel: task.model, reasoning: effort) {
            lines.append("Now on " + ([live.model] + [live.reasoning].compactMap { $0 }).joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    /// The tooltip's first line, `Codex · gpt-5.5 · high`: the model by its label in `labels`, or by its id with none.
    static func modelLine(_ agent: AgentKind, _ model: String, _ effort: String?, labels: ModelLabels) -> String {
        ([SidebarModel.agentName(agent), labels[agent]?[model] ?? model] + [effort].compactMap { $0 }).joined(separator: " · ")
    }

    /// Text as one line: its runs of spaces and newlines each one space.
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

public extension OperatorRun {
    /// The open question asking you about `task`'s fix rounds (`OperatorQuestion.fixRounds`), answered under Waiting on you.
    func fixRoundsQuestion(on task: UUID) -> OperatorQuestion? {
        questions.first { $0.task == task && $0.kind == .fixRounds && $0.resolution == nil }
    }
}
