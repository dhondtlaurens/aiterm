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

/// The `run_status()` answer (spec §6): a numbered snapshot of the operation and every task, and
/// the **open obligations** — what waits on you or on the operator. It is the operator's memory
/// after a restart or a compaction, so it says everything the operator acts on, and only that.
public struct RunStatus: Encodable, Equatable, Sendable {
    public struct Run: Encodable, Equatable, Sendable {
        public var id: UUID, name: String, state: OperatorRunState, prompt: String, review: String?, done: String?
        /// The last submitted revision, the open one `create_task` adds to, and the last approved.
        public var planRevision: Int, openRevision: Int, approvedRevision: Int?
        public var gated: Bool
        public init(id: UUID, name: String, state: OperatorRunState, prompt: String, review: String? = nil, done: String? = nil,
                    planRevision: Int, openRevision: Int, approvedRevision: Int? = nil, gated: Bool) {
            self.id = id; self.name = name; self.state = state; self.prompt = prompt; self.review = review; self.done = done
            self.planRevision = planRevision; self.openRevision = openRevision; self.approvedRevision = approvedRevision
            self.gated = gated
        }
    }

    public struct Dependency: Encodable, Equatable, Sendable {
        public var key: String, kind: DependencyKind
        public init(key: String, kind: DependencyKind) { self.key = key; self.kind = kind }
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
        public init(id: UUID, key: String, title: String, project: String, agent: AgentKind, model: String,
                    state: OperatedState, end: TaskEnd, revision: Int, live: SessionState? = nil, branch: String,
                    lastCommit: String? = nil, summary: String? = nil, dependsOn: [Dependency] = [],
                    acceptedSHA: String? = nil, blockedReason: String? = nil, flags: [OperatedFlag] = [],
                    takenOver: Bool = false, retriesUsed: Int = 0) {
            self.id = id; self.key = key; self.title = title; self.project = project; self.agent = agent; self.model = model
            self.state = state; self.end = end; self.revision = revision; self.live = live; self.branch = branch
            self.lastCommit = lastCommit; self.summary = summary; self.dependsOn = dependsOn
            self.acceptedSHA = acceptedSHA; self.blockedReason = blockedReason; self.flags = flags
            self.takenOver = takenOver; self.retriesUsed = retriesUsed
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
        /// The submitted revision waiting for your approval, in a gated run (`PlanRevision.awaitsApproval`).
        public var planAwaitingApproval: Int?
        public init(questionsWaiting: [Question] = [], promptsWaitingOnYou: [String] = [], readyForAcceptance: [String] = [],
                    possiblyStalled: [String] = [], uncertain: [String] = [], planAwaitingApproval: Int? = nil) {
            self.questionsWaiting = questionsWaiting; self.promptsWaitingOnYou = promptsWaitingOnYou
            self.readyForAcceptance = readyForAcceptance; self.possiblyStalled = possiblyStalled
            self.uncertain = uncertain; self.planAwaitingApproval = planAwaitingApproval
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
    public static func build(state: AppState, run id: UUID, revision: Int, live: [UUID: TaskLiveFacts]) -> RunStatus? {
        guard let run = state.run(id: id) else { return nil }
        let items = state.tasks(inRun: id)
        let keys = Dictionary(items.compactMap { item in item.operated.map { (item.id, $0.key) } }, uniquingKeysWith: { first, _ in first })
        var lines: [TaskLine] = []
        var prompts: [String] = [], ready: [String] = [], stalled: [String] = [], uncertain: [String] = []
        for item in items {
            guard let o = item.operated else { continue }
            let facts = live[item.id] ?? TaskLiveFacts()
            lines.append(TaskLine(
                id: item.id, key: o.key, title: item.title, project: state.project(id: item.projectId)?.name ?? "",
                agent: item.agent, model: item.model, state: o.state, end: o.end, revision: o.revision,
                live: facts.status, branch: item.branch, lastCommit: facts.lastCommit, summary: facts.summary,
                dependsOn: o.dependsOn.map { Dependency(key: keys[$0.task] ?? $0.task.uuidString, kind: $0.kind) },
                acceptedSHA: o.acceptance?.resultSHA, blockedReason: o.blockedReason,
                flags: o.flags.sorted { $0.rawValue < $1.rawValue }, takenOver: o.takenOver, retriesUsed: o.retriesUsed))
            if facts.waitingPrompt != nil || o.flags.contains(.waitingOnYou) { prompts.append(o.key) }
            else if o.state == .working, !o.takenOver, facts.status == .idle || facts.status == .done { ready.append(o.key) }
            if o.flags.contains(.possiblyStalled) { stalled.append(o.key) }
            if o.flags.contains(.uncertain) { uncertain.append(o.key) }
        }
        return RunStatus(
            revision: revision,
            run: Run(id: run.id, name: run.name, state: run.state, prompt: run.prompt, review: run.review, done: run.done,
                     planRevision: run.planRevision, openRevision: run.openRevision,
                     approvedRevision: run.approvedRevision, gated: run.gatesPlans),
            tasks: lines,
            obligations: Obligations(
                questionsWaiting: run.questions.filter { $0.resolution == nil }.map {
                    Question(key: $0.id, text: $0.text, task: $0.task.flatMap { keys[$0] }, askedAt: $0.askedAt)
                },
                promptsWaitingOnYou: prompts, readyForAcceptance: ready, possiblyStalled: stalled, uncertain: uncertain,
                planAwaitingApproval: PlanRevision.awaitsApproval(run) ? run.planRevision : nil))
    }

    /// The snapshot as the tool returns it: JSON with sorted keys and ISO 8601 dates.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
