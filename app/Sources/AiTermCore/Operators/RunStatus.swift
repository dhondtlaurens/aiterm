import Foundation

/// What AiTerm knows of a task's session beyond `state.json`: its live status, the branch's last
/// commit, a one-line summary, and a prompt waiting on you. Gathered by the caller from the daemon
/// snapshot and git; `RunStatus` only arranges it.
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
        public init(key: String, agent: AgentKind, model: String, status: SessionState? = nil, opening: Bool = false, closed: Bool = false,
                    waitingPrompt: String? = nil) {
            self.key = key; self.agent = agent; self.model = model; self.status = status; self.opening = opening; self.closed = closed
            self.waitingPrompt = waitingPrompt
        }
        /// What it counts as: `WorkerTab.status`.
        public var counted: SessionState? { opening ? .working : status }
    }

    /// The first worker's live status.
    public var status: SessionState?
    public var lastCommit: String?
    public var summary: String?
    /// The classified prompt that waits on you in the first worker, `permission` or `unknown` (spec §7.2), if any.
    public var waitingPrompt: String?
    /// The task's extra worker tabs, in the order asked for.
    public var tabs: [Tab]
    /// What its workers that ended their turn left running in the background (`WorkerTab.background`).
    public var background: [String]
    /// The prompt you typed into one of its workers yourself, for the turn it started (`SessionInfo.yourPrompt`).
    public var yourPrompt: String?
    /// What its first worker's ended turn left (spec §J), read once each turn ends and only while that worker is idle at its
    /// prompt or done: its last message, and how many commits its branch has past where its work starts (a working task's
    /// only, `Repository.commitsAhead`; nil while unknown).
    public var lastMessage: String?, commitsAhead: Int?
    /// An accepted, inReview or published task's worktree moved on from its accepted commit (`WorkerTurn.changedAfterAcceptance`).
    public var changedAfterAcceptance: Bool
    /// Its first worker ended its turn and AiTerm is still reading it: not ready until what the turn left is known.
    public var turnUnread: Bool

    public init(status: SessionState? = nil, lastCommit: String? = nil, summary: String? = nil, waitingPrompt: String? = nil,
                tabs: [Tab] = [], background: [String] = [], yourPrompt: String? = nil, lastMessage: String? = nil,
                commitsAhead: Int? = nil, changedAfterAcceptance: Bool = false, turnUnread: Bool = false) {
        self.status = status; self.lastCommit = lastCommit; self.summary = summary; self.waitingPrompt = waitingPrompt
        self.tabs = tabs; self.background = background; self.yourPrompt = yourPrompt
        self.lastMessage = lastMessage; self.commitsAhead = commitsAhead; self.changedAfterAcceptance = changedAfterAcceptance
        self.turnUnread = turnUnread
    }

    /// Its first worker is idle at its prompt or done: what its turn left is its final word.
    var turnEnded: Bool { status == .idle || status == .done }
}

/// What AiTerm knows beyond `state.json` that belongs to the whole operation rather than one task:
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

/// The `run_status()` answer (spec §6): a numbered snapshot of the operation and every task, and
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
        public init(_ review: PeopleReview) {
            reviewers = review.reviewers
            unresolvedThreads = review.threads.values.filter { !$0 }.count
            resolvedThreads = review.threads.values.filter { $0 }.count
            approvals = review.approvals
        }
    }

    /// One of a task's worker tabs: its key (`main` for the first worker, `WorkerTab.firstKey`), agent, model and live
    /// status, and whether it is still opening or was closed.
    public struct TabLine: Encodable, Equatable, Sendable {
        public var key: String, agent: AgentKind, model: String
        public var live: SessionState?
        public var opening: Bool
        /// An extra tab that opened and is listed no more: AiTerm never opens it again.
        public var closed: Bool
        public init(key: String, agent: AgentKind, model: String, live: SessionState? = nil, opening: Bool = false, closed: Bool = false) {
            self.key = key; self.agent = agent; self.model = model; self.live = live; self.opening = opening; self.closed = closed
        }
    }

    public struct TaskLine: Encodable, Equatable, Sendable {
        public var id: UUID, key: String, title: String, project: String
        public var agent: AgentKind, model: String
        public var state: OperatedState, end: TaskEnd, revision: Int
        /// The first worker's live status; nil when it has none (not started, or its window is gone).
        public var live: SessionState?
        public var branch: String, lastCommit: String?, summary: String?
        public var dependsOn: [Dependency]
        public var acceptedSHA: String?, blockedReason: String?, mergeRefusal: String?
        public var flags: [OperatedFlag]
        public var takenOver: Bool, retriesUsed: Int
        public var agentReview: AgentReviewLine?, peopleReview: PeopleReviewLine?
        /// Its worker committed off its task branch: what AiTerm found, and the branch and SHA it found it on.
        public var branchDrift: BranchDrift?
        /// Every worker tab, the first worker first, when the Operator added any (`open_tab`); nil when it has only its first.
        public var tabs: [TabLine]?
        /// What its workers left running in the background when they ended their turn, which wakes them again; nil when
        /// nothing does.
        public var background: [String]?
        /// True while a turn you started by typing into one of its workers yourself runs (You in a worker's window A,
        /// 22 Oct 2026): leave the worker alone and read its result once the turn ends. Nil otherwise.
        public var youAreDriving: Bool?
        /// That prompt's first line.
        public var yourPrompt: String?
        public init(id: UUID, key: String, title: String, project: String, agent: AgentKind, model: String,
                    state: OperatedState, end: TaskEnd, revision: Int, live: SessionState? = nil, branch: String,
                    lastCommit: String? = nil, summary: String? = nil, dependsOn: [Dependency] = [],
                    acceptedSHA: String? = nil, blockedReason: String? = nil, flags: [OperatedFlag] = [],
                    takenOver: Bool = false, retriesUsed: Int = 0, agentReview: AgentReviewLine? = nil,
                    peopleReview: PeopleReviewLine? = nil, branchDrift: BranchDrift? = nil, tabs: [TabLine]? = nil, background: [String]? = nil,
                    yourPrompt: String? = nil, mergeRefusal: String? = nil) {
            self.id = id; self.key = key; self.title = title; self.project = project; self.agent = agent; self.model = model
            self.state = state; self.end = end; self.revision = revision; self.live = live; self.branch = branch
            self.lastCommit = lastCommit; self.summary = summary; self.dependsOn = dependsOn
            self.acceptedSHA = acceptedSHA; self.blockedReason = blockedReason; self.flags = flags
            self.takenOver = takenOver; self.retriesUsed = retriesUsed
            self.agentReview = agentReview; self.peopleReview = peopleReview; self.branchDrift = branchDrift
            self.tabs = tabs; self.background = background
            self.youAreDriving = yourPrompt == nil ? nil : true; self.yourPrompt = yourPrompt
            self.mergeRefusal = mergeRefusal
        }
    }

    public struct Question: Encodable, Equatable, Sendable {
        public var key: String, text: String, task: String?, askedAt: Date
        public init(key: String, text: String, task: String? = nil, askedAt: Date) {
            self.key = key; self.text = text; self.task = task; self.askedAt = askedAt
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
        /// result, then `mark_task`.
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
        /// noChange or steer it.
        public var finishedWithoutCommit: [String]
        public init(questionsWaiting: [Question] = [], promptsWaitingOnYou: [String] = [], readyForAcceptance: [String] = [],
                    background: [String] = [], possiblyStalled: [String] = [], uncertain: [String] = [], branchDrift: [String] = [],
                    workerAsks: [WorkerAsk] = [], changedAfterAcceptance: [String] = [], finishedWithoutCommit: [String] = []) {
            self.questionsWaiting = questionsWaiting; self.promptsWaitingOnYou = promptsWaitingOnYou
            self.readyForAcceptance = readyForAcceptance; self.background = background; self.possiblyStalled = possiblyStalled
            self.uncertain = uncertain; self.branchDrift = branchDrift
            self.workerAsks = workerAsks; self.changedAfterAcceptance = changedAfterAcceptance
            self.finishedWithoutCommit = finishedWithoutCommit
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

    /// The snapshot of `run` in `state`; nil for a run the workspace does not have.
    public static func build(state: AppState, run id: UUID, revision: Int, live: [UUID: TaskLiveFacts],
                             runLive: RunLiveFacts = RunLiveFacts()) -> RunStatus? {
        guard let run = state.run(id: id) else { return nil }
        let items = state.tasks(inRun: id)
        let keys = Dictionary(items.compactMap { item in item.operated.map { (item.id, $0.key) } }, uniquingKeysWith: { first, _ in first })
        var lines: [TaskLine] = []
        var prompts: [String] = [], ready: [String] = [], background: [String] = [], stalled: [String] = [], uncertain: [String] = [], drift: [String] = []
        var asks: [WorkerAsk] = [], changed: [String] = [], noCommit: [String] = []
        for item in items {
            guard let o = item.operated else { continue }
            let facts = live[item.id] ?? TaskLiveFacts()
            lines.append(TaskLine(
                id: item.id, key: o.key, title: item.title, project: state.project(id: item.projectId)?.name ?? "",
                agent: item.agent, model: item.model, state: o.state, end: o.end, revision: o.revision,
                live: facts.status, branch: item.branch, lastCommit: facts.lastCommit, summary: facts.summary,
                dependsOn: o.dependsOn.map { Dependency(key: keys[$0.task] ?? $0.task.uuidString, kind: $0.kind) },
                acceptedSHA: o.acceptance?.resultSHA, blockedReason: o.blockedReason,
                flags: o.flags.sorted { $0.rawValue < $1.rawValue }, takenOver: o.takenOver, retriesUsed: o.retriesUsed,
                agentReview: o.agentReview.map(AgentReviewLine.init), peopleReview: o.peopleReview.map(PeopleReviewLine.init),
                branchDrift: o.branchDrift, tabs: tabLines(item, facts), background: facts.background.isEmpty ? nil : facts.background,
                yourPrompt: facts.yourPrompt,
                // As on its card: a task finished or taken over is past the refusal.
                mergeRefusal: o.takenOver || o.isFinished ? nil : o.publication?.mergeRefusal))
            // What the first worker's ended turn left, on a task in any state but yours (spec §J): a new turn is at work.
            let turn = facts.turnEnded && !o.takenOver && o.state != .stopped
            let asking = turn && WorkerTurn.endsWithQuestion(facts.lastMessage)
            if asking, let message = facts.lastMessage { asks.append(WorkerAsk(key: o.key, question: WorkerTurn.question(message))) }
            if turn, facts.changedAfterAcceptance, [.accepted, .inReview, .published].contains(o.state) { changed.append(o.key) }
            let tabPrompts = facts.tabs.filter { $0.waitingPrompt != nil }.map { "\(o.key)/\($0.key)" }
            if facts.waitingPrompt != nil || !tabPrompts.isEmpty {
                // Only a prompt open in a terminal is listed: the task's key stands for its first worker's prompt.
                prompts += (facts.waitingPrompt != nil ? [o.key] : []) + tabPrompts
            } else if !o.flags.contains(.waitingOnYou), !facts.turnUnread,
                      isReadyForAcceptance(o, live: facts.status, extraTabs: facts.tabs.map(\.counted), asks: asking) {
                if !facts.background.isEmpty { background.append(o.key) }
                else if facts.commitsAhead == 0 { noCommit.append(o.key) }
                else { ready.append(o.key) }
            }
            if o.flags.contains(.possiblyStalled) { stalled.append(o.key) }
            if o.flags.contains(.uncertain) { uncertain.append(o.key) }
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
                    Question(key: $0.id, text: $0.text, task: $0.task.flatMap { keys[$0] }, askedAt: $0.askedAt)
                },
                promptsWaitingOnYou: prompts, readyForAcceptance: ready, background: background, possiblyStalled: stalled, uncertain: uncertain,
                branchDrift: drift, workerAsks: asks, changedAfterAcceptance: changed, finishedWithoutCommit: noCommit))
    }

    /// A working task whose every worker ended its turn, idle at its prompt or done, with nothing left running in the
    /// `background`, and not yours: its result waits for the Operator's check. `status` is its first worker's;
    /// `extraTabs` its extra tabs' (`WorkerTab.status`), where nil is one closed, no worker any more. A prompt waiting
    /// on you is told apart by the caller. Its worker's turn ended with a question (`asks`), or with no commit past where
    /// its work starts (`commitsAhead` 0; nil is unknown), is not ready either (spec §E).
    public static func isReadyForAcceptance(_ task: OperatedTask, live status: SessionState?, extraTabs: [SessionState?] = [],
                                            background: [String] = [], asks: Bool = false, commitsAhead: Int? = nil) -> Bool {
        let ended: (SessionState?) -> Bool = { $0 == .idle || $0 == .done }
        return task.state == .working && !task.takenOver && ended(status) && extraTabs.allSatisfy { $0 == nil || ended($0) }
            && background.isEmpty && !asks && commitsAhead != 0
    }

    /// The task's worker tabs as its line lists them, the first worker as `main`; nil when it has no extra tab.
    private static func tabLines(_ item: TaskItem, _ facts: TaskLiveFacts) -> [TabLine]? {
        guard !facts.tabs.isEmpty else { return nil }
        return [TabLine(key: WorkerTab.firstKey, agent: item.agent, model: item.model, live: facts.status)]
            + facts.tabs.map { TabLine(key: $0.key, agent: $0.agent, model: $0.model, live: $0.status, opening: $0.opening, closed: $0.closed) }
    }

    /// The snapshot as the tool returns it: JSON with sorted keys and ISO 8601 dates.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
