import Foundation

public extension TaskItem {
    /// Sets the agent row for the stage about to launch, keeping the earlier stage's row for a drop to restore.
    mutating func useAgentRow(_ row: AgentChoice) {
        if signalTask?.previousStage != nil, signalTask?.previousStage?.agent == nil {
            signalTask?.previousStage?.agent = AgentChoice(agent: agent, model: model, reasoning: reasoning)
        }
        agent = row.agent; model = row.model; reasoning = row.reasoning
    }
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
    /// What a merge still lacks, as the host watch last read it for this stage; a new stage clears it.
    public var waitingOn: SignalWaitFacts?
    /// Whether this stage's Done query matched its item when last read completely, first before its worker launched.
    /// Done is the change from not matching to matching; a new stage clears it.
    public var doneMatched: Bool?
    /// AiTerm's own merge of this stage's request, saved just before the host call. While the stage carries it, the
    /// request merged at that head is AiTerm's doing: the stage goes back to its worker instead of ending. A new stage
    /// clears it.
    public var merge: SignalMerge?
    /// The stage that ran before this one, as it was left, kept until this one's worker starts: a stage dropped before
    /// its launch gives the task back to it, still watching its Done trigger or done with its Then.
    public var previousStage: EarlierStage?
    public var thenApplied: Bool?
    /// The scheduled run this task started from, kept for good: across its stages, and when another signal continues
    /// it, so the schedule still knows its previous run is unfinished. Nil for a task that started from an item.
    public var scheduledRun: SignalRunRef?
    public var ownership = 0
    public var blockedReason: String?
    public var journal: [TaskJournal.Entry] = []
    public init(current: SignalStage, startedAt: Date) { self.current = current; self.startedAt = startedAt }
    public var canRunThen: Bool { phase == .done && pendingStages.isEmpty }
    public var needsWorkerReads: Bool { phase.isActive }
    /// Configured sources and retained completed tasks need no model session. Pending stages
    /// and Then's closeout still belong to the current workload, including while paused.
    /// Really done: the stage's Done trigger fired and its closeout is through (done or archived, no pending stage,
    /// its Then applied), so it no longer keeps the Operator's session. A pause no longer applies to it.
    public var isFinished: Bool {
        switch phase {
        case .done, .archived: return !keepsOperatorSession
        default: return false
        }
    }
    public var keepsOperatorSession: Bool {
        switch phase {
        case .launching, .choosing, .working, .watching, .blocked: return true
        case .done: return !pendingStages.isEmpty || thenApplied != true
        case .archived: return !pendingStages.isEmpty
        case .unknown: return false
        }
    }
}

/// A stage as it was left when the next one continued the task: what a dropped stage restores.
public struct EarlierStage: Codable, Equatable, Sendable {
    public var stage: SignalStage
    public var phase: TaskPhase
    public var doneMatched: Bool?
    public var waitingOn: SignalWaitFacts?
    public var merge: SignalMerge?
    public var launch: LaunchAttempt?
    public var choice: AgentChoiceRecord?
    /// The task's agent row while that stage ran, kept once the next stage's launch sets another (`useAgentRow`).
    public var agent: AgentChoice?
    public init(of task: SignalTask) {
        stage = task.current; phase = task.phase; doneMatched = task.doneMatched; waitingOn = task.waitingOn
        merge = task.merge; launch = task.launch; choice = task.choice
    }
}

/// AiTerm's merge of a stage's request, from just before the host call until the stage ends.
public struct SignalMerge: Codable, Equatable, Sendable {
    public var request: SignalRequestRef
    /// The head commit AiTerm asked the host to merge.
    public var head: String
    /// Whether the host answered that it merged; until then a read showing the request merged at `head` settles it.
    public var accepted = false
    /// The merge commit, once the host has named it.
    public var commit: String?
    /// Whether the carry-on line has still to reach the worker.
    public var handBackOwed = true
    public init(request: SignalRequestRef, head: String) { self.request = request; self.head = head }

    /// Whether a read of `reference` showing it merged at `head` is this merge.
    public func merged(_ reference: SignalRequestRef?, at head: String?) -> Bool {
        reference == request && (accepted || head == self.head)
    }
    /// The one line the worker gets: `AiTerm merged !7 at 1a2b3c4; carry on.`, with GitHub's `#7`.
    public var line: String { said("carry on") }
    /// Why the stage blocks when the line has no worker to reach.
    public var workerGone: String { said("its worker is gone") }
    private func said(_ rest: String) -> String {
        let host: CodeHost = RemoteURL(request.remote)?.host?.lowercased() == "github.com" ? .gitHub : .gitLab
        return "AiTerm merged \(host.reference(request.number)) at \(String((commit ?? head).prefix(7))); \(rest)."
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
    /// Waiting for its Done trigger, or for its merge.
    case watching
    case blocked
    case done
    case archived
    case unknown(JSONValue)

    static func savedCase(kind: String?, value: SavedEnumValue) throws -> Self? {
        switch kind {
        case "launching": return .launching
        case "choosing": return .choosing
        case "working": return .working
        case "watching": return .watching
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
            case .watching: return .known("watching")
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
