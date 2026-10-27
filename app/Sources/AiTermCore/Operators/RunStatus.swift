import Foundation

/// What AiTerm knows of a task's session beyond `state.json`: its live status, its tabs, a prompt
/// waiting on you, and what its last turn left. Gathered by the caller from the daemon snapshot and
/// git; `RunStatus` only arranges it.
public struct TaskLiveFacts: Equatable, Sendable {
    /// An extra worker tab the Operator added (`open_tab`), as `WorkerTab` counts it.
    public struct Tab: Equatable, Sendable {
        public var key: String, agent: AgentKind, model: String
        /// Its tab's live status; nil while none is listed.
        public var status: SessionState?
        /// Asked for, its agent not shown yet (`WorkerTab.isOpening`): at work.
        public var opening: Bool
        /// Opened and listed no more (`WorkerTab.isClosed`): never opened again.
        public var closed: Bool
        /// The prompt it waits on you with, if any.
        public var waitingPrompt: String?
        /// The model and effort it runs now, and what became of the slash commands sent to it: `TaskLiveFacts`'s, for this tab.
        public var liveModel: String?, liveReasoning: String?
        public var slashCommands: [SlashCommand]
        public init(key: String, agent: AgentKind, model: String, status: SessionState? = nil, opening: Bool = false, closed: Bool = false,
                    waitingPrompt: String? = nil, liveModel: String? = nil, liveReasoning: String? = nil, slashCommands: [SlashCommand] = []) {
            self.key = key; self.agent = agent; self.model = model; self.status = status; self.opening = opening; self.closed = closed
            self.waitingPrompt = waitingPrompt
            self.liveModel = liveModel; self.liveReasoning = liveReasoning; self.slashCommands = slashCommands
        }
        /// What it counts as: `WorkerTab.status`.
        public var counted: SessionState? { opening ? .working : status }
    }

    /// The first worker's live status.
    public var status: SessionState?
    /// The classified prompt that waits on you in the first worker, `permission` or `unknown` (spec §7.2), if any.
    public var waitingPrompt: String?
    /// The task's extra worker tabs, in the order asked for.
    public var tabs: [Tab]
    /// What its workers left running in the background (`WorkerTab.background`): what one that ended its turn left, and
    /// the subagents that hold one at working after its turn ended.
    public var background: [String]
    /// The prompt you typed into one of its workers yourself, for the turn it started (`SessionInfo.yourPrompt`).
    public var yourPrompt: String?
    /// What its first worker's ended turn left (spec §J), read once each turn ends and only while that worker is idle at its
    /// prompt or done: its last message, and how many commits its branch has past where its work starts (a working task's
    /// only, `Repository.commitsAhead`; nil while unknown).
    public var lastMessage: String?, commitsAhead: Int?
    /// A reopened working task's HEAD is still the commit it was accepted on (`OperatedTask.reopenedFrom`): no new commit,
    /// and that one to accept again.
    public var atReopenedCommit: Bool
    /// An accepted, inReview or published task's worktree moved on from its accepted commit (`WorkerTurn.changedAfterAcceptance`).
    public var changedAfterAcceptance: Bool
    /// Its first worker ended its turn and AiTerm is still reading it: not ready until what the turn left is known.
    public var turnUnread: Bool
    /// Its first worker's session says working but its transcript has not grown for `OperatorTiming.liveQuietMinutes`
    /// (`StallWatch.isQuietWhileWorking`): the line reads `working?` and the task is uncertain.
    public var quiet: Bool
    /// The model and effort its first worker runs now, as Claude Code itself reported them (`SessionInfo.model`,
    /// `.reasoning`): changed once a /model or /effort has run, never by delivering one, and never a subagent's. Nil while
    /// it hasn't said.
    public var liveModel: String?, liveReasoning: String?
    /// What became of the slash commands `message_task` typed into its first worker (`SessionInfo.slashCommands`).
    public var slashCommands: [SlashCommand]
    /// What ended one of its workers' turns short, as a sentence (`StoppedOn.reason`): a usage limit and when it resets,
    /// or a billing or sign-in failure. Nil while none is.
    public var stoppedOn: String?

    public init(status: SessionState? = nil, waitingPrompt: String? = nil,
                tabs: [Tab] = [], background: [String] = [], yourPrompt: String? = nil, lastMessage: String? = nil,
                commitsAhead: Int? = nil, atReopenedCommit: Bool = false, changedAfterAcceptance: Bool = false, turnUnread: Bool = false,
                quiet: Bool = false, liveModel: String? = nil, liveReasoning: String? = nil, slashCommands: [SlashCommand] = [],
                stoppedOn: String? = nil) {
        self.status = status; self.waitingPrompt = waitingPrompt
        self.tabs = tabs; self.background = background; self.yourPrompt = yourPrompt
        self.lastMessage = lastMessage; self.commitsAhead = commitsAhead; self.atReopenedCommit = atReopenedCommit
        self.changedAfterAcceptance = changedAfterAcceptance
        self.turnUnread = turnUnread; self.quiet = quiet
        self.liveModel = liveModel; self.liveReasoning = liveReasoning; self.slashCommands = slashCommands
        self.stoppedOn = stoppedOn
    }

    /// Its first worker is idle at its prompt or done: what its turn left is its final word.
    var turnEnded: Bool { status?.turnEnded == true }
}

/// What AiTerm knows beyond `state.json` that belongs to the whole broadcast rather than one task:
/// each agent's weekly usage, in percent, for the agents whose window is still open, and what each
/// installed agent may run. Gathered by the caller from the sidebar's usage readings and Settings ›
/// Agents; `RunStatus` only passes it on.
public struct RunLiveFacts: Equatable, Sendable {
    public var weeklyUsage: [AgentKind: Int]
    /// The installed agents the Operator chooses from, each with its own models (spec §15).
    public var agents: [AgentKind: RunStatus.AgentChoice]

    public init(weeklyUsage: [AgentKind: Int] = [:], agents: [AgentKind: RunStatus.AgentChoice] = [:]) {
        self.weeklyUsage = weeklyUsage; self.agents = agents
    }
}

/// The `run_status()` answer (spec §6): a numbered snapshot of the broadcast and every task, and
/// the **open obligations** — what waits on you or on the operator. It is the operator's memory
/// after a restart or a compaction, so it says everything the operator acts on, and only that.
public struct RunStatus: Encodable, Equatable, Sendable {
    /// What an installed agent may run (spec §15): the model ids in its own list in Settings › Agents, and
    /// the model and reasoning a task starts on when the Operator names none; and whether its workers can be
    /// messaged, nil while AiTerm's helper can't say.
    public struct AgentChoice: Encodable, Equatable, Sendable {
        public var models: [String], defaultModel: String, defaultReasoning: String?
        public var delivery: AgentDelivery?
        public init(models: [String], defaultModel: String, defaultReasoning: String? = nil, delivery: AgentDelivery? = nil) {
            self.models = models; self.defaultModel = defaultModel; self.defaultReasoning = defaultReasoning; self.delivery = delivery
        }
    }

    /// A snag the Operator reported: the rest of it is kept beside the summary.
    public struct SnagLine: Encodable, Equatable, Sendable {
        public var key: String, title: String
        public init(key: String, title: String) { self.key = key; self.title = title }
    }

    public struct Run: Encodable, Equatable, Sendable {
        public var id: UUID, name: String, state: OperatorRunState, prompt: String, review: String?, done: String?
        /// The last submitted revision, and the open one `create_task` adds to.
        public var planRevision: Int, openRevision: Int
        /// How many tasks the first submitted plan had, nil before one is submitted: what the backlog's growth is measured against.
        public var firstPlanSize: Int?
        /// The off-brief finds so far, never worked on.
        public var finds: [OffBriefFind]
        /// What AiTerm got wrong that the Operator worked around, by key and title.
        public var snags: [SnagLine]
        public var jiraProjectKeys: [String]
        /// What the Operator may do beyond the base, as this broadcast froze it.
        public var slices: Slices
        /// Whether the Oracle challenges the Operator's calls in this broadcast.
        public var oracleIsOn: Bool
        /// Each agent's weekly usage in percent, by the agent's raw value; an agent with no open window is left out.
        public var usage: [String: Int]
        /// Each installed agent's models and default, by the agent's raw value; an agent not installed is left out.
        public var agents: [String: AgentChoice]
        /// The run is complete and its summary is not written: the Operator writes it with `write_summary`.
        public var summaryDue: Bool
        public init(id: UUID, name: String, state: OperatorRunState, prompt: String, review: String? = nil, done: String? = nil,
                    planRevision: Int, openRevision: Int, firstPlanSize: Int? = nil, finds: [OffBriefFind] = [], snags: [SnagLine] = [],
                    slices: Slices = .none, oracleIsOn: Bool = false, usage: [String: Int] = [:], agents: [String: AgentChoice] = [:], jiraProjectKeys: [String] = [],
                    summaryDue: Bool = false) {
            self.id = id; self.name = name; self.state = state; self.prompt = prompt; self.review = review; self.done = done
            self.planRevision = planRevision; self.openRevision = openRevision; self.firstPlanSize = firstPlanSize
            self.jiraProjectKeys = jiraProjectKeys
            self.finds = finds; self.snags = snags; self.slices = slices; self.oracleIsOn = oracleIsOn; self.usage = usage; self.agents = agents
            self.summaryDue = summaryDue
        }
    }

    public struct Dependency: Encodable, Equatable, Sendable {
        public var key: String, kind: DependencyKind
        public init(key: String, kind: DependencyKind) { self.key = key; self.kind = kind }
    }

    /// A task's agent review: by whom, and `running`, `done` (its findings read with `read_task`, `what: review`) or `failed`.
    public struct AgentReviewLine: Encodable, Equatable, Sendable {
        public var agent: AgentKind, state: String
        public init(agent: AgentKind, state: String) { self.agent = agent; self.state = state }
        public init(_ review: AgentReviewResult) {
            self.init(agent: review.agent, state: review.isRunning ? "running" : review.findings != nil ? "done" : "failed")
        }
    }

    /// People's review of a task's request, as AiTerm last read it: who was asked, its threads, who approved.
    public struct PeopleReviewLine: Encodable, Equatable, Sendable {
        public var reviewers: [String], unresolvedThreads: Int, resolvedThreads: Int, approvals: [String]
        /// When the task went into review.
        public var startedAt: Date?
        public init(_ review: PeopleReview) {
            startedAt = review.startedAt
            reviewers = review.reviewers
            unresolvedThreads = review.threads.values.filter { !$0 }.count
            resolvedThreads = review.threads.values.filter { $0 }.count
            approvals = review.approvals
        }
    }

    /// A worker's live status as `run_status` says it: the session's own, except `working?` for one that says working with
    /// its transcript gone quiet (`TaskLiveFacts.quiet`), which the Operator doesn't take on trust (spec §H).
    public enum LiveState: String, Encodable, Equatable, Sendable {
        case idle, working, needsInput, done
        case workingQuiet = "working?"

        public init(_ state: SessionState, quiet: Bool = false) {
            switch state {
            case .idle: self = .idle
            case .working: self = quiet ? .workingQuiet : .working
            case .needsInput: self = .needsInput
            case .done: self = .done
            }
        }
    }

    /// A slash command `message_task` typed into a worker, and what became of it, with its evidence: `delivered`, typed
    /// and nothing of it in its transcript yet; `queued`, Claude Code queued it at `seenAt` and has taken nothing from its
    /// queue since; `ran`, its transcript recorded it run at `seenAt`, with a local command's `output`; `unknown`, nothing of
    /// it in its transcript within a minute or no transcript to read, something left its queue after it was queued, or an
    /// hour passed without its run, and within that hour it can still become `ran`, but not once a remove, popAll or popOne
    /// named it, nor, never queued, once the same text was sent again. A /model or /effort run mid-turn takes effect and
    /// writes nothing, so it reads unknown: its line's `liveModel` and `liveReasoning` say what it runs.
    public struct SlashCommandLine: Encodable, Equatable, Sendable {
        public var text: String, state: SlashCommand.State, deliveredAt: Date, seenAt: Date?, output: String?
        public init(text: String, state: SlashCommand.State, deliveredAt: Date, seenAt: Date? = nil, output: String? = nil) {
            self.text = text; self.state = state; self.deliveredAt = deliveredAt; self.seenAt = seenAt; self.output = output
        }
        public init(_ command: SlashCommand) {
            self.init(text: command.text, state: command.state, deliveredAt: Date(timeIntervalSince1970: command.deliveredAt),
                      seenAt: command.seenAt.map(Date.init(timeIntervalSince1970:)), output: command.output)
        }

        /// Each of `commands` as a line; nil for none.
        static func lines(_ commands: [SlashCommand]) -> [SlashCommandLine]? { commands.isEmpty ? nil : commands.map(SlashCommandLine.init) }
    }

    /// One of a task's worker tabs: its key (`main` for the first worker, `WorkerTab.firstKey`), agent, model and live
    /// status, whether it is still opening or was closed, the model and effort it runs now and what became of the slash
    /// commands sent to it.
    public struct TabLine: Encodable, Equatable, Sendable {
        public var key: String, agent: AgentKind, model: String
        public var live: LiveState?
        public var opening: Bool
        /// An extra tab that opened and is listed no more: AiTerm never opens it again.
        public var closed: Bool
        public var liveModel: String?, liveReasoning: String?
        public var slashCommands: [SlashCommandLine]?
        public init(key: String, agent: AgentKind, model: String, live: LiveState? = nil, opening: Bool = false, closed: Bool = false,
                    liveModel: String? = nil, liveReasoning: String? = nil, slashCommands: [SlashCommandLine]? = nil) {
            self.key = key; self.agent = agent; self.model = model; self.live = live; self.opening = opening; self.closed = closed
            self.liveModel = liveModel; self.liveReasoning = liveReasoning; self.slashCommands = slashCommands
        }
    }

    public struct TaskLine: Encodable, Equatable, Sendable {
        public var id: UUID, key: String, title: String, project: String
        public var agent: AgentKind, model: String
        public var state: OperatedState, end: TaskEnd, revision: Int
        /// The first worker's live status; nil when it has none (not started, or its window is gone).
        public var live: LiveState?
        public var branch: String
        public var dependsOn: [Dependency]
        public var acceptedSHA: String?, blockedReason: String?, mergeRefusal: String?
        public var flags: [OperatedFlag]
        public var takenOver: Bool, retriesUsed: Int
        public var agentReview: AgentReviewLine?, peopleReview: PeopleReviewLine?
        /// Its worker committed off its task branch: what AiTerm found, and the branch and SHA it found it on.
        public var branchDrift: BranchDrift?
        /// Every worker tab, the first worker first, when the Operator added any (`open_tab`); nil when it has only its first.
        public var tabs: [TabLine]?
        /// What its workers left running in the background when they ended their turn, which wakes them again: of one its
        /// subagents hold at working, only those. Nil when nothing does.
        public var background: [String]?
        /// True while a turn you started by typing into one of its workers yourself runs (You in a worker's window A,
        /// 22 Oct 2026): leave the worker alone and read its result once the turn ends. Nil otherwise.
        public var youAreDriving: Bool?
        /// That prompt's first line.
        public var yourPrompt: String?
        /// What the host says of its request now: draft, pipeline, mergeability, approvals. Not built here: the `run_status`
        /// tool reads the host, off the main thread, and fills it in; nil for a task with no request, or when the host did not answer.
        public var mergeRequest: MergeRequestState?
        /// Why `mergeRequest` is nil for a task that has a request: the host did not answer in time, or refused.
        public var mergeRequestNote: String?
        /// The commit a working task was accepted on before it was steered back to work (spec §C, §D). Listed ready with no
        /// commit past it, it is that commit to accept again; nil for a task not reopened.
        public var reopenedFrom: String?
        /// The model and effort its first worker runs now, as Claude Code reported them: a /model confirmed in its window
        /// shows here, while `model` stays the one it was planned on. Nil while its worker hasn't said, and for an agent
        /// other than Claude.
        public var liveModel: String?, liveReasoning: String?
        /// What became of the slash commands `message_task` typed into its first worker, oldest first; nil when none was.
        public var slashCommands: [SlashCommandLine]?
        /// Why one of its workers stopped short of finishing its turn, an API error Claude Code reported: a usage limit and
        /// when it resets, or a billing or sign-in failure that waits on the person. Not ready while it says so; nil otherwise.
        public var stoppedOn: String?
        public init(id: UUID, key: String, title: String, project: String, agent: AgentKind, model: String,
                    state: OperatedState, end: TaskEnd, revision: Int, live: LiveState? = nil, branch: String,
                    dependsOn: [Dependency] = [],
                    acceptedSHA: String? = nil, blockedReason: String? = nil, flags: [OperatedFlag] = [],
                    takenOver: Bool = false, retriesUsed: Int = 0, agentReview: AgentReviewLine? = nil,
                    peopleReview: PeopleReviewLine? = nil, branchDrift: BranchDrift? = nil, tabs: [TabLine]? = nil, background: [String]? = nil,
                    yourPrompt: String? = nil, mergeRefusal: String? = nil, reopenedFrom: String? = nil, liveModel: String? = nil,
                    liveReasoning: String? = nil, slashCommands: [SlashCommandLine]? = nil, stoppedOn: String? = nil) {
            self.id = id; self.key = key; self.title = title; self.project = project; self.agent = agent; self.model = model
            self.state = state; self.end = end; self.revision = revision; self.live = live; self.branch = branch
            self.dependsOn = dependsOn
            self.acceptedSHA = acceptedSHA; self.blockedReason = blockedReason; self.flags = flags
            self.takenOver = takenOver; self.retriesUsed = retriesUsed
            self.agentReview = agentReview; self.peopleReview = peopleReview; self.branchDrift = branchDrift
            self.tabs = tabs; self.background = background
            self.youAreDriving = yourPrompt == nil ? nil : true; self.yourPrompt = yourPrompt
            self.mergeRefusal = mergeRefusal; self.reopenedFrom = reopenedFrom
            self.liveModel = liveModel; self.liveReasoning = liveReasoning; self.slashCommands = slashCommands
            self.stoppedOn = stoppedOn
        }
    }

    public struct Question: Encodable, Equatable, Sendable {
        public var key: String, text: String, task: String?, askedAt: Date
        /// The newest prompt (its first line) you typed into the task's worker window while this was open: it may answer
        /// the question. Check, then resolve it. Nil when none.
        public var answeredInWindow: String?
        public init(key: String, text: String, task: String? = nil, askedAt: Date, answeredInWindow: String? = nil) {
            self.key = key; self.text = text; self.task = task; self.askedAt = askedAt; self.answeredInWindow = answeredInWindow
        }
    }

    /// A worker whose turn ended with a question (spec §J), on a task in any state: `question` is its last paragraph
    /// (`WorkerTurn.question`). Read it, and answer with message_task, before acting on the task.
    public struct WorkerAsk: Encodable, Equatable, Sendable {
        public var key: String, question: String
        public init(key: String, question: String) { self.key = key; self.question = question }
    }

    public struct Obligations: Encodable, Equatable, Sendable {
        public var questionsWaiting: [Question]
        /// Task keys whose worker waits on a prompt for you; the operator only tells you. A prompt in an extra tab
        /// names it after its task's key: `PAY-2/tests`.
        public var promptsWaitingOnYou: [String]
        /// Working tasks whose worker ended its turn with no question and a commit past where its work starts: check the
        /// result, then `mark_task`. A reopened one still on the commit it was accepted on (its line's `reopenedFrom`) is
        /// here too: accept that commit again.
        public var readyForAcceptance: [String]
        /// Working tasks whose worker ended its turn with work still running in the background, which wakes it again
        /// once it ends: not ready yet. Each task's line says what runs.
        public var background: [String]
        public var possiblyStalled: [String]
        public var uncertain: [String]
        /// Tasks whose worker committed off its task branch (`TaskLine.branchDrift`): its work isn't where AiTerm reads it.
        public var branchDrift: [String]
        /// Workers that ended their turn asking something, on tasks in any state (spec §J). A working one is not ready.
        public var workerAsks: [WorkerAsk]
        /// Accepted, inReview or published tasks whose worktree moved on from the accepted commit once their worker's turn
        /// ended: changes not committed, or another HEAD. Someone worked there after the acceptance.
        public var changedAfterAcceptance: [String]
        /// Working tasks whose worker ended its turn with no commit past where its work starts (spec §E): not ready; mark it
        /// noChange or steer it. Never a reopened one on its accepted commit, which is ready to accept again.
        public var finishedWithoutCommit: [String]
        /// InReview tasks with nothing waiting (spec §K): no unresolved thread, no worker's question and no change after
        /// acceptance, for `OperatorTiming.reviewQuietMinutes` since the review began. The Operator decides against the Done
        /// whether the review is over; AiTerm doesn't read the Done.
        public var reviewQuiet: [String]
        public init(questionsWaiting: [Question] = [], promptsWaitingOnYou: [String] = [], readyForAcceptance: [String] = [],
                    background: [String] = [], possiblyStalled: [String] = [], uncertain: [String] = [], branchDrift: [String] = [],
                    workerAsks: [WorkerAsk] = [], changedAfterAcceptance: [String] = [], finishedWithoutCommit: [String] = [],
                    reviewQuiet: [String] = []) {
            self.questionsWaiting = questionsWaiting; self.promptsWaitingOnYou = promptsWaitingOnYou
            self.readyForAcceptance = readyForAcceptance; self.background = background; self.possiblyStalled = possiblyStalled
            self.uncertain = uncertain; self.branchDrift = branchDrift
            self.workerAsks = workerAsks; self.changedAfterAcceptance = changedAfterAcceptance
            self.finishedWithoutCommit = finishedWithoutCommit; self.reviewQuiet = reviewQuiet
        }
    }

    /// Numbers the snapshots, so the operator can tell a new one from one it has read.
    public var revision: Int
    public var run: Run
    public var tasks: [TaskLine]
    public var obligations: Obligations

    public init(revision: Int, run: Run, tasks: [TaskLine] = [], obligations: Obligations = Obligations()) {
        self.revision = revision; self.run = run; self.tasks = tasks; self.obligations = obligations
    }

    /// The snapshot of `run` in `state` as of `now`, which the quiet review is measured against; nil for a run the workspace
    /// does not have.
    public static func build(state: AppState, run id: UUID, revision: Int, live: [UUID: TaskLiveFacts],
                             runLive: RunLiveFacts = RunLiveFacts(), now: Date = Date()) -> RunStatus? {
        guard let run = state.run(id: id) else { return nil }
        let items = state.tasks(inRun: id)
        let keys = Dictionary(items.compactMap { item in item.operated.map { (item.id, $0.key) } }, uniquingKeysWith: { first, _ in first })
        var lines: [TaskLine] = []
        var prompts: [String] = [], ready: [String] = [], background: [String] = [], stalled: [String] = [], uncertain: [String] = [], drift: [String] = []
        var asks: [WorkerAsk] = [], changed: [String] = [], noCommit: [String] = [], reviewQuiet: [String] = []
        for item in items {
            guard let o = item.operated else { continue }
            let facts = live[item.id] ?? TaskLiveFacts()
            lines.append(TaskLine(
                id: item.id, key: o.key, title: item.title, project: state.project(id: item.projectId)?.name ?? "",
                agent: item.agent, model: item.model, state: o.state, end: o.end, revision: o.revision,
                live: facts.status.map { LiveState($0, quiet: facts.quiet) }, branch: item.branch,
                dependsOn: o.dependsOn.map { Dependency(key: keys[$0.task] ?? $0.task.uuidString, kind: $0.kind) },
                acceptedSHA: o.acceptance?.resultSHA, blockedReason: o.blockedReason,
                flags: o.flags.sorted { $0.rawValue < $1.rawValue }, takenOver: o.takenOver, retriesUsed: o.retriesUsed,
                agentReview: o.agentReview.map(AgentReviewLine.init), peopleReview: o.peopleReview.map(PeopleReviewLine.init),
                branchDrift: o.branchDrift, tabs: tabLines(item, facts), background: facts.background.isEmpty ? nil : facts.background,
                yourPrompt: facts.yourPrompt,
                // As on its card: a task finished or taken over is past the refusal.
                mergeRefusal: o.takenOver || o.isFinished ? nil : o.publication?.mergeRefusal,
                reopenedFrom: o.state == .working ? o.reopenedFrom : nil, liveModel: facts.liveModel, liveReasoning: facts.liveReasoning,
                slashCommands: SlashCommandLine.lines(facts.slashCommands), stoppedOn: facts.stoppedOn))
            // What the first worker's ended turn left, on a task in any state but yours (spec §J): a new turn is at work.
            let turn = facts.turnEnded && !o.takenOver && o.state != .stopped
            let asking = turn && WorkerTurn.endsWithQuestion(facts.lastMessage)
            if asking, let message = facts.lastMessage { asks.append(WorkerAsk(key: o.key, question: WorkerTurn.question(message))) }
            let moved = turn && facts.changedAfterAcceptance && [.accepted, .inReview, .published].contains(o.state)
            if moved { changed.append(o.key) }
            if !asking, !moved, isReviewQuiet(o, now: now) { reviewQuiet.append(o.key) }
            let tabPrompts = facts.tabs.filter { $0.waitingPrompt != nil }.map { "\(o.key)/\($0.key)" }
            if facts.waitingPrompt != nil || !tabPrompts.isEmpty {
                // Only a prompt open in a terminal is listed: the task's key stands for its first worker's prompt.
                prompts += (facts.waitingPrompt != nil ? [o.key] : []) + tabPrompts
            } else if !o.flags.contains(.waitingOnYou), !facts.turnUnread, facts.stoppedOn == nil,
                      isReadyForAcceptance(o, live: facts.status, extraTabs: facts.tabs.map(\.counted), asks: asking) {
                if !facts.background.isEmpty { background.append(o.key) }
                // A reopened task with no new commit, still on the one it was accepted on, has that commit to accept again.
                else if facts.commitsAhead == 0, !(o.reopenedFrom != nil && facts.atReopenedCommit) { noCommit.append(o.key) }
                else { ready.append(o.key) }
            }
            if o.flags.contains(.possiblyStalled) { stalled.append(o.key) }
            if o.flags.contains(.uncertain) || (facts.quiet && facts.status == .working) { uncertain.append(o.key) }
            if o.branchDrift != nil { drift.append(o.key) }
        }
        return RunStatus(
            revision: revision,
            run: Run(id: run.id, name: run.name, state: run.state, prompt: run.prompt, review: run.review, done: run.done,
                     planRevision: run.planRevision, openRevision: run.openRevision, firstPlanSize: run.firstPlanSize,
                     finds: run.finds, snags: run.snags.map { SnagLine(key: $0.key, title: $0.title) }, slices: run.profile.slices, oracleIsOn: run.profile.oracle.isOn,
                     usage: Dictionary(runLive.weeklyUsage.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { first, _ in first }),
                     agents: Dictionary(runLive.agents.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { first, _ in first }), jiraProjectKeys: run.jiraProjectKeys,
                     summaryDue: run.state == .complete && run.summary == nil),
            tasks: lines,
            obligations: Obligations(
                questionsWaiting: run.questions.filter { $0.resolution == nil }.map {
                    Question(key: $0.id, text: $0.text, task: $0.task.flatMap { keys[$0] }, askedAt: $0.askedAt,
                             answeredInWindow: $0.answeredInWindow)
                },
                promptsWaitingOnYou: prompts, readyForAcceptance: ready, background: background, possiblyStalled: stalled, uncertain: uncertain,
                branchDrift: drift, workerAsks: asks, changedAfterAcceptance: changed, finishedWithoutCommit: noCommit,
                reviewQuiet: reviewQuiet))
    }

    /// A review of yours to end, not yours: in review, not ended, not taken over, no unresolved thread, and begun at least
    /// `OperatorTiming.reviewQuietMinutes` before `now`. What else waits (a worker's question, work after acceptance) the
    /// caller rules out.
    private static func isReviewQuiet(_ task: OperatedTask, now: Date) -> Bool {
        guard task.state == .inReview, !task.takenOver, let review = task.peopleReview, !review.ended,
              let began = review.startedAt else { return false }
        return !review.threads.values.contains(false) && now.timeIntervalSince(began) >= TimeInterval(OperatorTiming.reviewQuietMinutes) * 60
    }

    /// A working task whose every worker ended its turn, idle at its prompt or done, with nothing left running in the
    /// `background`, and not yours: its result waits for the Operator's check. `status` is its first worker's;
    /// `extraTabs` its extra tabs' (`WorkerTab.status`), where nil is one closed, no worker any more. A prompt waiting
    /// on you is told apart by the caller. Its worker's turn ended with a question (`asks`) is not ready either (spec §E);
    /// one with no commit past where its work starts is told apart by `build`, as `finishedWithoutCommit`.
    public static func isReadyForAcceptance(_ task: OperatedTask, live status: SessionState?, extraTabs: [SessionState?] = [],
                                            background: [String] = [], asks: Bool = false) -> Bool {
        let ended: (SessionState?) -> Bool = { $0?.turnEnded == true }
        return task.state == .working && !task.takenOver && ended(status) && extraTabs.allSatisfy { $0 == nil || ended($0) }
            && background.isEmpty && !asks
    }

    /// The task's worker tabs as its line lists them, the first worker as `main`; nil when it has no extra tab.
    private static func tabLines(_ item: TaskItem, _ facts: TaskLiveFacts) -> [TabLine]? {
        guard !facts.tabs.isEmpty else { return nil }
        return [TabLine(key: WorkerTab.firstKey, agent: item.agent, model: item.model, live: facts.status.map { LiveState($0, quiet: facts.quiet) },
                        liveModel: facts.liveModel, liveReasoning: facts.liveReasoning, slashCommands: SlashCommandLine.lines(facts.slashCommands))]
            + facts.tabs.map { TabLine(key: $0.key, agent: $0.agent, model: $0.model, live: $0.status.map { LiveState($0) }, opening: $0.opening,
                                       closed: $0.closed, liveModel: $0.liveModel, liveReasoning: $0.liveReasoning,
                                       slashCommands: SlashCommandLine.lines($0.slashCommands)) }
    }

    /// The snapshot as the tool returns it: JSON with sorted keys and ISO 8601 dates.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
