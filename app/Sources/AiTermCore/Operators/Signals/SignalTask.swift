import Foundation

/// Saved before typing or launching. An old transcript cannot finish a newly sent turn.
public struct SignalWorkerReply: Codable, Equatable, Sendable {
    public var at: Date
    public var fingerprint: String?
    public init(at: Date, fingerprint: String?) { self.at = at; self.fingerprint = fingerprint }
}

public struct SignalTask: Codable, Equatable, Sendable {
    public var signal: UUID
    public var item: ItemRef
    public var configuration: Signal?
    public var prompt: String?
    public var candidateProjects: [UUID]?
    public var phase: TaskPhase = .launching
    public var stage: Int = 1
    public var startedAt: Date
    public var pendingStages: [SignalStage] = []
    public var pendingReplies: [String: SignalWorkerReply]?
    public var launch: LaunchAttempt?
    public var extraTabs: [ExtraTab] = []
    public var peopleReview: PeopleReview?
    public var watchedRequest: SignalRequestRef?
    public var thenApplied: Bool?
    public var currentAct: String?
    public var takenOver = false
    public var ownership = 0
    public var blockedReason: String?
    public var edges: [SignalEdge] = []
    public var journal: [TaskJournal.Entry] = []
    public init(signal: UUID, item: ItemRef, startedAt: Date) { self.signal = signal; self.item = item; self.startedAt = startedAt }
    public var canRunThen: Bool { phase == .done && pendingStages.isEmpty && !takenOver }
    public var needsWorkerReads: Bool { !takenOver && phase.isActive }
}
