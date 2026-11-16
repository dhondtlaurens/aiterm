import Foundation

/// Saved before typing or launching. An old transcript cannot finish a newly sent turn.
public struct SignalWorkerReply: Codable, Equatable, Sendable {
    public var at: Date
    public var fingerprint: String?
    public init(at: Date, fingerprint: String?) { self.at = at; self.fingerprint = fingerprint }
}

public struct SignalTask: Codable, Equatable, Sendable {
    /// Durable journals retain history; state keeps the latest transitions for inspection.
    public static let edgeLimit = 100
    public var signal: UUID
    public var item: ItemRef
    public var configuration: Signal?
    public var prompt: String?
    public var candidateProjects: [UUID]?
    /// While `choosing`: the rows the Operator may choose among, in the person's order.
    public var choosableRows: [AgentChoice]?
    /// The row and project this stage was given, and why. Cleared when a new stage starts.
    public var choice: AgentChoiceRecord?
    public var phase: TaskPhase = .launching
    public var stage: Int = 1
    public var startedAt: Date
    public var pendingStages: [SignalStage] = []
    public var pendingReplies: [String: SignalWorkerReply]?
    public var launch: LaunchAttempt?
    public var extraTabs: [ExtraTab] = []
    public var peopleReview: PeopleReview?
    public var watchedRequest: SignalRequestRef?
    /// The reviewers and open threads the done check last read for this stage; a new stage clears it.
    public var waitingOn: SignalWaitFacts?
    public var thenApplied: Bool?
    public var operatorJudged: Bool?
    public var currentAct: String?
    public var takenOver = false
    public var ownership = 0
    public var blockedReason: String?
    public var edges: [SignalEdge] = []
    public var journal: [TaskJournal.Entry] = []
    public init(signal: UUID, item: ItemRef, startedAt: Date) { self.signal = signal; self.item = item; self.startedAt = startedAt }
    public var canRunThen: Bool { phase == .done && pendingStages.isEmpty && !takenOver }
    public var needsWorkerReads: Bool { !takenOver && phase.isActive }
    /// Configured sources and retained completed tasks need no model session. Pending stages
    /// and Then's closeout still belong to the current workload, including while paused.
    public var keepsOperatorSession: Bool {
        guard !takenOver else { return false }
        switch phase {
        case .launching, .choosing, .working, .watching, .blocked: return true
        case .done: return !pendingStages.isEmpty || thenApplied != true
        case .archived: return !pendingStages.isEmpty
        case .stopped, .unknown: return false
        }
    }
}
