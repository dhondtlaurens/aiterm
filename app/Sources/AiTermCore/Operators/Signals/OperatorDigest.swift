import Foundation

/// AiTerm-built session context. Descriptions are deliberately absent: read_task supplies quoted
/// host text on demand. Only our journal entries appear as durable notes.
public struct OperatorDigest: Encodable, Equatable, Sendable {
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
    }
    public struct TaskLine: Encodable, Equatable, Sendable {
        public var id: UUID
        public var project: UUID
        public var ownership: Int
        public var candidates: [UUID]?
        public var permittedAgents: [AgentChoice]
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
    }
    public var schema = 1
    public var generatedAt: Date
    public var oracleOn: Bool
    public var projects: [ProjectLine]
    public var signals: [Signal]
    public var tasks: [TaskLine]
    public var questions: [OperatorSession.Question]
    public var waitingOnYou: Int
    public init(state: AppState, at: Date, oracleOn: Bool, task: UUID? = nil) {
        generatedAt = at; self.oracleOn = oracleOn; signals = state.signals
        projects = state.projects.map { ProjectLine(id: $0.id, name: $0.name, path: $0.path) }
        tasks = state.allSignalTasks.compactMap { value in
            guard task == nil || task == value.id, let record = value.signalTask, !record.takenOver else { return nil }
            let configuration = record.configuration ?? state.signal(id: record.signal)
            let tabs = record.extraTabs.map {
                TabLine(key: $0.key, agent: $0.agent, model: $0.model, reasoning: $0.reasoning, session: $0.sessionId)
            }
            let pending = record.pendingStages.map { PendingLine(signal: $0.signal, item: $0.item, matchedAt: $0.matchedAt) }
            let journal = record.journal.filter { if case .ours = $0.text { true } else { false } }
            return TaskLine(id: value.id, project: value.projectId, ownership: record.ownership,
                            candidates: record.candidateProjects, permittedAgents: configuration?.agents ?? [],
                            blockedReason: record.blockedReason, currentAct: record.currentAct, tabs: tabs,
                            signal: record.signal, item: record.item, agent: value.agent, model: value.model,
                            reasoning: value.reasoning, prompt: configuration?.work.prompt, finish: configuration?.finish,
                            request: record.watchedRequest, branch: value.branch, stage: record.stage,
                            phase: record.phase, pending: pending, journal: Array(journal.suffix(TaskJournal.stateLimit)))
        }
        questions = (state.operatorSession?.questions ?? []).filter { $0.resolvedAt == nil && (task == nil || task == $0.task) }
        waitingOnYou = questions.count
    }
}
