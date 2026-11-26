import Foundation

public struct LaunchAttempt: Codable, Equatable, Sendable {
    public var number: Int
    public var requestedAt: Date
    /// When its worker's window was first seen — recorded by AiTerm, nil while it may still be
    /// opening. A launch that showed a window is never launched again: a worker whose window you
    /// closed comes back on your click, its conversation resumed, never as a second worker.
    public var openedAt: Date?
    /// True while this attempt awaits its first worker. `SignalWorkerIO.recoverLaunches` reads it to recover a saved
    /// launch from a tagged tab running the planned agent, or block the task when the tab is not that worker.
    public var workerPending: Bool?
    public init(number: Int, requestedAt: Date, openedAt: Date? = nil, workerPending: Bool? = nil) {
        self.number = number; self.requestedAt = requestedAt; self.openedAt = openedAt; self.workerPending = workerPending
    }
}

public struct ExtraTab: Codable, Equatable, Sendable {
    /// The Operator's idempotency key, unique within its task: `open_tab` with this key returns this tab.
    public var key: String
    public var agent: AgentKind
    public var model: String
    public var reasoning: String?
    /// Why the Operator chose its agent and model, in its words.
    public var modelReason: String
    /// The tab's first prompt as the Operator wrote it, before AiTerm's own lines (`TabOpener.prompt`).
    public var brief: String
    /// Its latest request; `openedAt` once its tab was seen. A tab that showed is never asked for again.
    public var launch: LaunchAttempt
    /// The session it opened, as iTerm2 names it: the daemon's answer, or the tagged tab the reconciler found.
    public var sessionId: String?
    /// Why the daemon refused to open it, when it did; nil while it is open or may still open.
    public var failure: String?
    /// The conversation its agent last named (`SessionInfo.conversationId`): read once its tab is closed, and never taken
    /// for the first worker's (`TaskItem.firstWorkerConversation`).
    public var conversation: String?

    public init(key: String, agent: AgentKind, model: String, reasoning: String?, modelReason: String, brief: String,
                launch: LaunchAttempt, sessionId: String? = nil, failure: String? = nil,
                conversation: String? = nil) {
        self.key = key; self.agent = agent; self.model = model; self.reasoning = reasoning; self.modelReason = modelReason
        self.brief = brief; self.launch = launch; self.sessionId = sessionId; self.failure = failure
        self.conversation = conversation
    }
}

public struct GateRequest: Codable, Equatable, Sendable {
    public var command: String
    public var directory: String
    public init(command: String, directory: String) { self.command = command; self.directory = directory }
}

public struct OperatorSnag: Codable, Equatable, Sendable {
    public var key: String, title: String, showed: String, actual: String, workaround: String
    public var evidence: String?
    public var task: UUID?, taskKey: String?, branch: String?
    public var appVersion: String, at: Date
    public init(key: String, title: String, showed: String, actual: String, workaround: String, evidence: String? = nil,
                task: UUID? = nil, taskKey: String? = nil, branch: String? = nil, appVersion: String, at: Date) {
        self.key = key; self.title = title; self.showed = showed; self.actual = actual; self.workaround = workaround
        self.evidence = evidence; self.task = task; self.taskKey = taskKey; self.branch = branch
        self.appVersion = appVersion; self.at = at
    }
}

public struct OracleRound: Codable, Equatable, Sendable, Identifiable {
    /// Only finished rounds are saved: an agreed worker answer about to be delivered, a critique waiting for a
    /// revised proposal, or a binding that went to the person.
    public enum Stage: String, Codable, CaseIterable, Sendable {
        case ready, delivered, unanswered
    }

    public var id: String
    public var tool: String
    public var stage: OracleRound.Stage
    /// The Oracle's answer, once it gave one.
    public var critique: String?
    /// The evidence binding this round to its task or question.
    public var askedEvidence: String?
    /// Why the action proceeded without the Oracle's agreement: it was missing, failed or too slow.
    public var unansweredReason: String?
    /// The call's answer, as the JSON the Operator read.
    public var result: String?
    public var askedAt: Date
    /// The Oracle round, starting at 1; nil when the call has no discussion.
    public var round: Int?
    /// The Operator's proposal or reply to the Oracle, which the next round reads.
    public var reply: String?

    public init(id: String, tool: String, stage: OracleRound.Stage, critique: String? = nil,
                unansweredReason: String? = nil,
                result: String? = nil, askedAt: Date, askedEvidence: String? = nil, round: Int? = nil) {
        self.id = id; self.tool = tool; self.stage = stage; self.critique = critique
        self.unansweredReason = unansweredReason; self.result = result
        self.askedAt = askedAt; self.askedEvidence = askedEvidence; self.round = round
    }
}

public struct PausedWorker: Codable, Hashable, Sendable {
    public var task: UUID
    public var tab: String?
    public var ownership: Int

    public init(task: UUID, tab: String?, ownership: Int) {
        self.task = task; self.tab = tab; self.ownership = ownership
    }
}
