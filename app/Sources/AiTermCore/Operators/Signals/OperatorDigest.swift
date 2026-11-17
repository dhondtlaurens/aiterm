import Foundation

/// AiTerm-built session context. Descriptions are deliberately absent: read_task supplies quoted
/// host text on demand. Our decisions and explicitly quoted steering survive fresh sessions.
public struct OperatorDigest: Encodable, Equatable, Sendable {
    public struct WorkerLine: Encodable, Equatable, Sendable {
        public var task: UUID
        public var session: String
        public var tab: String
        public var agent: SessionAgent
        public var state: SessionState
        public var conversation: String?
        public var contextTokens: Int?
        public var contextPercent: Int?
        public var backgroundJobs: Int
    }
    public struct ProjectLine: Encodable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var path: String
    }
    public struct PendingLine: Encodable, Equatable, Sendable {
        public var signal: UUID
        public var item: ItemRef
        public var matchedAt: Date
    }
    public struct TabLine: Encodable, Equatable, Sendable {
        public var key: String
        public var agent: AgentKind
        public var model: String
        public var reasoning: String?
        public var session: String?
        public var conversation: String?
        /// Why the Operator chose this tab's row.
        public var reason: String?
    }
    public struct TaskLine: Encodable, Equatable, Sendable {
        public var id: UUID
        public var project: UUID
        public var ownership: Int
        public var candidates: [UUID]?
        public var permittedAgents: [AgentChoice]
        /// While choosing: the rows choose_agent accepts, in the person's order.
        public var choosableRows: [AgentChoice]?
        /// The row (and project) this stage was given, its reason and how it was decided.
        public var choice: AgentChoiceRecord?
        public var blockedReason: String?
        public var currentAct: String?
        public var tabs: [TabLine]
        public var signal: UUID
        public var item: ItemRef
        public var agent: AgentKind
        public var model: String
        public var reasoning: String?
        public var prompt: String?
        public var finish: SignalFinish?
        public var request: SignalRequestRef?
        public var branch: String
        public var stage: Int
        public var phase: TaskPhase
        public var pending: [PendingLine]
        public var journal: [TaskJournal.Entry]
        public var pendingReplies: [String: SignalWorkerReply] = [:]
    }
    public var weeklyUsage: [String: Int]
    /// The agents installed on this Mac that the Operator can start.
    public var installedAgents: [AgentKind]
    /// What is going wrong between AiTerm and the Operator now, per source; `needsYou` says whether
    /// the Operator row shows it to the person.
    public var appIssues: [OperatorIssues.Issue]
    public var snags: [OperatorSnag]
    public var oracleRounds: [ChallengeRecord]
    public var skipped: [SignalSeen]
    public var sourceFailures: [String: String]
    public var workers: [WorkerLine]
    public var generation: Int?
    public var paused: Bool
    public var standingInstructions: String?
    public var schema = 1
    public var generatedAt: Date
    public var oracleOn: Bool
    public var projects: [ProjectLine]
    public var signals: [Signal]
    public var tasks: [TaskLine]
    public var questions: [OperatorSession.Question]
    public var waitingOnYou: Int
    public init(state: AppState, at: Date, oracleOn: Bool, task: UUID? = nil,
                sessions: [SessionInfo] = [], instructions: String? = nil, usage: UsageSnapshot = .empty, installed: Set<AgentKind> = [],
                issues: [OperatorIssues.Issue] = []) {
        installedAgents = AgentCommand.operatedAgents.filter(installed.contains); appIssues = issues
        weeklyUsage = Dictionary(uniqueKeysWithValues: SidebarModel.weeklyUsage(usage, now: at).map { ($0.key.rawValue, $0.value) })
        snags = Array((state.operatorSession?.snags ?? []).suffix(100))
        oracleRounds = state.operatorSession?.oracleRounds ?? []
        skipped = state.signalSeen.filter { $0.disposition == .skipped && $0.isMatching && state.signal(id: $0.signal) != nil }
        sourceFailures = state.operatorSession?.sourceFailures ?? [:]
        generation = state.operatorSession?.generation; paused = state.operatorSession?.paused == true
        standingInstructions = instructions
        let ids = Set(state.allSignalTasks.filter { $0.signalTask?.takenOver == false && (task == nil || $0.id == task) }.map(\.id))
        workers = sessions.compactMap { session in
            guard let id = session.taskUUID, ids.contains(id) else { return nil }
            return WorkerLine(task: id, session: session.sessionId, tab: session.tabKey ?? "main", agent: session.agent, state: session.state,
                              conversation: session.conversationId, contextTokens: session.contextTokens, contextPercent: session.contextPercent,
                              backgroundJobs: session.background.count)
        }
        generatedAt = at; self.oracleOn = oracleOn; signals = state.signals
        projects = state.projects.map { ProjectLine(id: $0.id, name: $0.name, path: $0.path) }
        tasks = state.allSignalTasks.compactMap { value in
            guard task == nil || task == value.id, let record = value.signalTask, !record.takenOver else { return nil }
            let configuration = record.configuration ?? state.signal(id: record.signal)
            let tabs = [TabLine(key: "main", agent: value.agent, model: value.model, reasoning: value.reasoning, session: nil, conversation: value.firstWorkerConversation?.id)] + record.extraTabs.map {
                TabLine(key: $0.key, agent: $0.agent, model: $0.model, reasoning: $0.reasoning, session: $0.sessionId, conversation: $0.conversation, reason: $0.modelReason)
            }
            let pending = record.pendingStages.map { PendingLine(signal: $0.signal, item: $0.item, matchedAt: $0.matchedAt) }
            let journal = record.journal.filter {
                switch $0.text {
                case .ours: true
                case .quoted(let quote): quote.source == "operator instruction"
                default: false
                }
            }
            var line = TaskLine(id: value.id, project: value.projectId, ownership: record.ownership,
                            candidates: record.candidateProjects, permittedAgents: configuration?.agents ?? [],
                            choosableRows: record.choosableRows, choice: record.choice,
                            blockedReason: record.blockedReason, currentAct: record.currentAct, tabs: tabs,
                            signal: record.signal, item: record.item, agent: value.agent, model: value.model,
                            reasoning: value.reasoning, prompt: task == nil ? nil : configuration?.work.prompt, finish: configuration?.finish,
                            request: record.watchedRequest, branch: value.branch, stage: record.stage,
                            phase: record.phase, pending: pending, journal: Array(journal.suffix(task == nil ? 1 : TaskJournal.stateLimit)))
            line.pendingReplies = record.pendingReplies ?? [:]
            return line
        }
        questions = (state.operatorSession?.questions ?? []).filter { ($0.resolvedAt == nil || ($0.workerQuestion != nil && $0.answer != nil && $0.deliveredAt == nil)) && (task == nil || task == $0.task) }
        waitingOnYou = questions.filter { $0.resolvedAt == nil }.count
    }
}
