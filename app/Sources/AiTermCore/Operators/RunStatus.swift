import Foundation

/// What AiTerm knows of a task's session beyond `state.json`: its live status, the branch's last
/// commit, a one-line summary, and a prompt waiting on you. Gathered by the caller from the daemon
/// snapshot and git; `RunStatus` only arranges it.
public struct TaskLiveFacts: Equatable, Sendable {
    public var status: SessionState?
    public var lastCommit: String?
    public var summary: String?
    /// The classified prompt that waits on you — `permission` or `unknown` (spec §7.2) — if any.
    public var waitingPrompt: String?

    public init(status: SessionState? = nil, lastCommit: String? = nil, summary: String? = nil, waitingPrompt: String? = nil) {
        self.status = status; self.lastCommit = lastCommit; self.summary = summary; self.waitingPrompt = waitingPrompt
    }
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
    /// the model and reasoning a task starts on when the Operator names none.
    public struct AgentChoice: Encodable, Equatable, Sendable {
        public var models: [String], defaultModel: String, defaultReasoning: String?
        public init(models: [String], defaultModel: String, defaultReasoning: String? = nil) {
            self.models = models; self.defaultModel = defaultModel; self.defaultReasoning = defaultReasoning
        }
    }

    public struct Run: Encodable, Equatable, Sendable {
        public var id: UUID, name: String, state: OperatorRunState, prompt: String, review: String?, done: String?
        /// The last submitted revision, and the open one `create_task` adds to.
        public var planRevision: Int, openRevision: Int
        /// How many tasks the first submitted plan had, nil before one is submitted: what the backlog's growth is measured against.
        public var firstPlanSize: Int?
        /// The off-brief finds so far, never worked on.
        public var finds: [OffBriefFind]
        public var jiraProjectKeys: [String]
        /// What the Operator may do beyond the base, as this broadcast froze it.
        public var slices: Slices
        /// Whether the Oracle challenges the Operator's calls in this broadcast.
        public var oracleIsOn: Bool
        /// Each agent's weekly usage in percent, by the agent's raw value; an agent with no open window is left out.
        public var usage: [String: Int]
        /// Each installed agent's models and default, by the agent's raw value; an agent not installed is left out.
        public var agents: [String: AgentChoice]
        public init(id: UUID, name: String, state: OperatorRunState, prompt: String, review: String? = nil, done: String? = nil,
                    planRevision: Int, openRevision: Int, firstPlanSize: Int? = nil, finds: [OffBriefFind] = [],
                    slices: Slices = .none, oracleIsOn: Bool = false, usage: [String: Int] = [:], agents: [String: AgentChoice] = [:], jiraProjectKeys: [String] = []) {
            self.id = id; self.name = name; self.state = state; self.prompt = prompt; self.review = review; self.done = done
            self.planRevision = planRevision; self.openRevision = openRevision; self.firstPlanSize = firstPlanSize
            self.jiraProjectKeys = jiraProjectKeys
            self.finds = finds; self.slices = slices; self.oracleIsOn = oracleIsOn; self.usage = usage; self.agents = agents
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

    public struct TaskLine: Encodable, Equatable, Sendable {
        public var id: UUID, key: String, title: String, project: String
        public var agent: AgentKind, model: String
        public var state: OperatedState, end: TaskEnd, revision: Int
        /// The session's live status; nil when it has none (not started, or its window is gone).
        public var live: SessionState?
        public var branch: String, lastCommit: String?, summary: String?
        public var dependsOn: [Dependency]
        public var acceptedSHA: String?, blockedReason: String?
        public var flags: [OperatedFlag]
        public var takenOver: Bool, retriesUsed: Int
        public var agentReview: AgentReviewLine?, peopleReview: PeopleReviewLine?
        /// Its worker committed off its task branch: what AiTerm found, and the branch and SHA it found it on.
        public var branchDrift: BranchDrift?
        public init(id: UUID, key: String, title: String, project: String, agent: AgentKind, model: String,
                    state: OperatedState, end: TaskEnd, revision: Int, live: SessionState? = nil, branch: String,
                    lastCommit: String? = nil, summary: String? = nil, dependsOn: [Dependency] = [],
                    acceptedSHA: String? = nil, blockedReason: String? = nil, flags: [OperatedFlag] = [],
                    takenOver: Bool = false, retriesUsed: Int = 0, agentReview: AgentReviewLine? = nil,
                    peopleReview: PeopleReviewLine? = nil, branchDrift: BranchDrift? = nil) {
            self.id = id; self.key = key; self.title = title; self.project = project; self.agent = agent; self.model = model
            self.state = state; self.end = end; self.revision = revision; self.live = live; self.branch = branch
            self.lastCommit = lastCommit; self.summary = summary; self.dependsOn = dependsOn
            self.acceptedSHA = acceptedSHA; self.blockedReason = blockedReason; self.flags = flags
            self.takenOver = takenOver; self.retriesUsed = retriesUsed
            self.agentReview = agentReview; self.peopleReview = peopleReview; self.branchDrift = branchDrift
        }
    }

    public struct Question: Encodable, Equatable, Sendable {
        public var key: String, text: String, task: String?, askedAt: Date
        public init(key: String, text: String, task: String? = nil, askedAt: Date) {
            self.key = key; self.text = text; self.task = task; self.askedAt = askedAt
        }
    }

    public struct Obligations: Encodable, Equatable, Sendable {
        public var questionsWaiting: [Question]
        /// Task keys whose worker waits on a prompt for you; the operator only tells you.
        public var promptsWaitingOnYou: [String]
        /// Working tasks whose worker ended its turn: check the result, then `mark_task`.
        public var readyForAcceptance: [String]
        public var possiblyStalled: [String]
        public var uncertain: [String]
        /// Tasks whose worker committed off its task branch (`TaskLine.branchDrift`): its work isn't where AiTerm reads it.
        public var branchDrift: [String]
        public init(questionsWaiting: [Question] = [], promptsWaitingOnYou: [String] = [], readyForAcceptance: [String] = [],
                    possiblyStalled: [String] = [], uncertain: [String] = [], branchDrift: [String] = []) {
            self.questionsWaiting = questionsWaiting; self.promptsWaitingOnYou = promptsWaitingOnYou
            self.readyForAcceptance = readyForAcceptance; self.possiblyStalled = possiblyStalled
            self.uncertain = uncertain; self.branchDrift = branchDrift
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
        var prompts: [String] = [], ready: [String] = [], stalled: [String] = [], uncertain: [String] = [], drift: [String] = []
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
                branchDrift: o.branchDrift))
            if facts.waitingPrompt != nil || o.flags.contains(.waitingOnYou) { prompts.append(o.key) }
            else if isReadyForAcceptance(o, live: facts.status) { ready.append(o.key) }
            if o.flags.contains(.possiblyStalled) { stalled.append(o.key) }
            if o.flags.contains(.uncertain) { uncertain.append(o.key) }
            if o.branchDrift != nil { drift.append(o.key) }
        }
        return RunStatus(
            revision: revision,
            run: Run(id: run.id, name: run.name, state: run.state, prompt: run.prompt, review: run.review, done: run.done,
                     planRevision: run.planRevision, openRevision: run.openRevision, firstPlanSize: run.firstPlanSize,
                     finds: run.finds, slices: run.profile.slices, oracleIsOn: run.profile.oracle.isOn,
                     usage: Dictionary(runLive.weeklyUsage.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { first, _ in first }),
                     agents: Dictionary(runLive.agents.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { first, _ in first }), jiraProjectKeys: run.jiraProjectKeys),
            tasks: lines,
            obligations: Obligations(
                questionsWaiting: run.questions.filter { $0.resolution == nil }.map {
                    Question(key: $0.id, text: $0.text, task: $0.task.flatMap { keys[$0] }, askedAt: $0.askedAt)
                },
                promptsWaitingOnYou: prompts, readyForAcceptance: ready, possiblyStalled: stalled, uncertain: uncertain,
                branchDrift: drift))
    }

    /// A working task whose worker ended its turn, idle at its prompt or done, and not yours: its result
    /// waits for the Operator's check. A prompt waiting on you is told apart by the caller.
    public static func isReadyForAcceptance(_ task: OperatedTask, live status: SessionState?) -> Bool {
        task.state == .working && !task.takenOver && (status == .idle || status == .done)
    }

    /// The snapshot as the tool returns it: JSON with sorted keys and ISO 8601 dates.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
