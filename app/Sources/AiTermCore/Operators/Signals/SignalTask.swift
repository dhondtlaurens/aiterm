import Foundation

public extension TaskItem {
    /// A task under the Operator is drawn under its signal, offers Take Over, and is not one of its project's own rows.
    var isUnderOperator: Bool { signalTask != nil }
}

/// Saved before typing or launching. An old transcript cannot finish a newly sent turn.
public struct SignalWorkerReply: Codable, Equatable, Sendable {
    public var at: Date
    public var fingerprint: String?
    public init(at: Date, fingerprint: String?) { self.at = at; self.fingerprint = fingerprint }
}

public struct SignalTask: Codable, Equatable, Sendable {
    /// The stage this task runs now: its signal, item, the signal's configuration as it was when
    /// the stage matched, and its prompt.
    public var current: SignalStage
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
    public var watchedRequest: SignalRequestRef?
    /// The reviewers and open threads the done check last read for this stage; a new stage clears it.
    public var waitingOn: SignalWaitFacts?
    public var thenApplied: Bool?
    public var operatorJudged: Bool?
    public var ownership = 0
    public var blockedReason: String?
    public var journal: [TaskJournal.Entry] = []
    public init(current: SignalStage, startedAt: Date) { self.current = current; self.startedAt = startedAt }
    public var canRunThen: Bool { phase == .done && pendingStages.isEmpty }
    public var needsWorkerReads: Bool { phase.isActive }
    /// Configured sources and retained completed tasks need no model session. Pending stages
    /// and Then's closeout still belong to the current workload, including while paused.
    public var keepsOperatorSession: Bool {
        switch phase {
        case .launching, .choosing, .working, .watching, .blocked: return true
        case .done: return !pendingStages.isEmpty || thenApplied != true
        case .archived: return !pendingStages.isEmpty
        case .unknown: return false
        }
    }
}

public struct SignalStage: Codable, Equatable, Sendable {
    public var signal: UUID
    public var item: ItemRef
    public var configuration: Signal
    public var prompt: String?
    public var matchedAt: Date
    public init(signal: UUID, item: ItemRef, matchedAt: Date, configuration: Signal, prompt: String? = nil) {
        self.signal = signal; self.item = item; self.matchedAt = matchedAt
        self.configuration = configuration; self.prompt = prompt
    }
}

public enum TaskPhase: KindTaggedEnum, Equatable, Sendable {
    case launching
    /// Waiting for the Operator to choose the stage's agent row or project; not the person's turn.
    case choosing
    case working
    case watching(DoneWhen)
    case blocked
    case done
    case archived
    case unknown(JSONValue)

    static func savedCase(kind: String?, value: SavedEnumValue) throws -> Self? {
        switch kind {
        case "launching": return .launching
        case "choosing": return .choosing
        case "working": return .working
        case "watching":
            return .watching(try value.decode(DoneWhen.self))
        case "blocked": return .blocked
        case "done": return .done
        case "archived": return .archived
        default: return nil
        }
    }

    var savedCase: SavedEnumCase {
        get throws {
            switch self {
            case .launching: return .known("launching")
            case .choosing: return .known("choosing")
            case .working: return .known("working")
            case .watching(let value): return .known("watching", try JSONValue(encoding: value))
            case .blocked: return .known("blocked")
            case .done: return .known("done")
            case .archived: return .known("archived")
            case .unknown(let value): return .unknown(value)
            }
        }
    }
}

public extension TaskPhase {
    var isActive: Bool { self == .launching || self == .working }
    var canContinue: Bool {
        switch self { case .watching, .done, .archived: true; default: false }
    }
}
