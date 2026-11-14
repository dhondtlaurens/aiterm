import Foundation

/// AiTerm-built session context. Descriptions are deliberately absent: read_task supplies quoted
/// host text on demand. Only our journal entries appear as durable notes.
public struct OperatorDigest: Encodable, Equatable, Sendable {
    public struct TaskLine: Encodable, Equatable, Sendable {
        public var id: UUID
        public var signal: UUID
        public var item: ItemRef
        public var branch: String
        public var stage: Int
        public var phase: TaskPhase
        public var pending: [SignalStage]
        public var journal: [TaskJournal.Entry]
    }
    public var schema = 1
    public var generatedAt: Date
    public var oracleOn: Bool
    public var signals: [Signal]
    public var tasks: [TaskLine]
    public var questions: [OperatorSession.Question]
    public var waitingOnYou: Int
    public init(state: AppState, at: Date, oracleOn: Bool, task: UUID? = nil) {
        generatedAt = at; self.oracleOn = oracleOn; signals = state.signals
        tasks = state.allSignalTasks.compactMap { value in
            guard task == nil || task == value.id, let record = value.signalTask, !record.takenOver else { return nil }
            return TaskLine(id: value.id, signal: record.signal, item: record.item, branch: value.branch, stage: record.stage,
                            phase: record.phase, pending: record.pendingStages,
                            journal: Array(record.journal.filter { if case .ours = $0.text { true } else { false } }.suffix(TaskJournal.stateLimit)))
        }
        questions = (state.operatorSession?.questions ?? []).filter { $0.resolvedAt == nil && (task == nil || task == $0.task) }
        waitingOnYou = questions.count
    }
}
