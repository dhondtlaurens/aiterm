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
    /// A trigger as the stage runs it: its source and query, and for an Operator Done the person's description of done,
    /// which is guidance for the Operator and the Oracle.
    public struct TriggerLine: Encodable, Equatable, Sendable {
        public var source: SignalTrigger.Source
        public var query: String
        public var doneLooksLike: String?
        init(_ trigger: SignalTrigger) {
            source = trigger.source; query = trigger.query
            if trigger.source == .operator { doneLooksLike = trigger.description.isEmpty ? "The prompt's work is complete." : trigger.description }
        }
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
        public var tabs: [TabLine]
        public var signal: UUID
        public var item: ItemRef
        public var agent: AgentKind
        public var model: String
        public var reasoning: String?
        public var prompt: String?
        /// The stage's own triggers and finish, as its signal was when the stage matched.
        public var start: TriggerLine
        public var done: TriggerLine
        public var finish: SignalFinish
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
    public var oracleRounds: [OracleRound]
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
    /// Each runnable scheduled signal's next run, by signal id; absent when there is none.
    public var nextRuns: [String: Date]?
    public var tasks: [TaskLine]
    public var questions: [OperatorSession.Question]
    public var waitingOnYou: Int
    public init(state: AppState, at: Date, oracleOn: Bool, task: UUID? = nil,
                sessions: [SessionInfo] = [], instructions: String? = nil, usage: UsageSnapshot = .empty, installed: Set<AgentKind> = [],
                issues: [OperatorIssues.Issue] = []) {
        installedAgents = AgentCommand.workerAgents.filter(installed.contains); appIssues = issues
        weeklyUsage = Dictionary(uniqueKeysWithValues: SidebarModel.weeklyUsage(usage, now: at).map { ($0.key.rawValue, $0.value) })
        snags = Array((state.operatorSession?.snags ?? []).suffix(100))
        oracleRounds = state.operatorSession?.oracleRounds ?? []
        // The Operator is told only of its own signals: a project signal's items, skips and runs are the person's.
        skipped = state.signalSeen.filter { $0.disposition == .skipped && $0.isMatching && state.signal(id: $0.signal)?.isProject == false }
        sourceFailures = state.operatorSession?.sourceFailures ?? [:]
        generation = state.operatorSession?.generation; paused = state.operatorSession?.paused == true
        standingInstructions = instructions
        let ids = Set(state.allSignalTasks.filter { task == nil || $0.id == task }.map(\.id))
        workers = sessions.compactMap { session in
            guard let id = session.taskUUID, ids.contains(id) else { return nil }
            return WorkerLine(task: id, session: session.sessionId, tab: session.tabKey ?? "main", agent: session.agent, state: session.state,
                              conversation: session.conversationId, contextTokens: session.contextTokens, contextPercent: session.contextPercent,
                              backgroundJobs: session.work.filter(\.holdsTurn).count)
        }
        let operatorSignals = state.signals.filter { !$0.isProject }
        generatedAt = at; self.oracleOn = oracleOn; signals = operatorSignals
        let runs = operatorSignals.filter { $0.isScheduled && $0.isRunnable }.reduce(into: [String: Date]()) { runs, signal in
            runs[signal.id.uuidString] = ScheduleDecision.nextRun(of: signal, cursor: state.scheduleCursors[signal.id], now: at,
                                                                  calendar: .autoupdatingCurrent)
        }
        nextRuns = runs.isEmpty ? nil : runs
        projects = state.projects.map { ProjectLine(id: $0.id, name: $0.name, path: $0.path) }
        tasks = state.allSignalTasks.compactMap { value in
            guard task == nil || task == value.id, let record = value.signalTask else { return nil }
            let configuration = record.current.configuration
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
                            candidates: record.candidateProjects, permittedAgents: configuration.agents,
                            choosableRows: record.choosableRows, choice: record.choice,
                            blockedReason: record.blockedReason, tabs: tabs,
                            signal: record.current.signal, item: record.current.item, agent: value.agent, model: value.model,
                            reasoning: value.reasoning, prompt: task == nil ? nil : configuration.work.prompt,
                            start: TriggerLine(configuration.start), done: TriggerLine(configuration.done), finish: configuration.finish,
                            request: record.watchedRequest, branch: value.branch, stage: record.stage,
                            phase: record.phase, pending: pending, journal: Array(journal.suffix(task == nil ? 1 : TaskJournal.stateLimit)))
            line.pendingReplies = record.pendingReplies ?? [:]
            return line
        }
        questions = (state.operatorSession?.questions ?? []).filter { $0.isPending && (task == nil || task == $0.task) }
        waitingOnYou = questions.filter { $0.resolvedAt == nil }.count
    }

    /// An item as the Oracle's checks name it: a ticket's key, a merge request's number, a run's scheduled time.
    public static func itemName(_ item: ItemRef) -> String {
        switch item {
        case .ticket(let ticket): ticket.key
        case .mergeRequest(let request): "!" + String(request.number)
        case .run(let run): "the scheduled run due " + run.at.formatted(.iso8601)
        case .unknown: "an item"
        }
    }
}
