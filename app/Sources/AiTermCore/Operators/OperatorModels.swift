import Foundation

public struct LaunchAttempt: Codable, Equatable, Sendable {
    public var number: Int
    public var requestedAt: Date
    /// When its worker's window was first seen — recorded by AiTerm, nil while it may still be
    /// opening. A launch that showed a window is never launched again: a worker whose window you
    /// closed comes back on your click, its conversation resumed, never as a second worker.
    public var openedAt: Date?
    /// True from just before AiTerm asks for this attempt's window or tab, where its agent command is typed, until a first
    /// worker running an agent is listed for the task; nil otherwise, and in every record from before it existed. A pending
    /// attempt whose window was seen `OperatorTiming.firstWorkerOpening` ago with still no agent is a launch that failed:
    /// AiTerm blocks the task and says so (`WorkerStarter.checkLaunches`), never leaving it working with no worker.
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
    public var requestedLaunch: LaunchRequest?
    /// Why the Operator chose its agent and model, in its words.
    public var modelReason: String
    /// The tab's first prompt as the Operator wrote it, before AiTerm's own lines (`TabOpener.prompt`).
    public var brief: String
    /// The person's words named its agent: it was not refused for an agent whose workers can't be messaged.
    public var agentPinned: Bool
    /// Its latest request; `openedAt` once its tab was seen. A tab that showed is never asked for again.
    public var launch: LaunchAttempt
    /// The session it opened, as iTerm2 names it: the daemon's answer, or the tagged tab the reconciler found.
    public var sessionId: String?
    /// Why the daemon refused to open it, when it did; nil while it is open or may still open.
    public var failure: String?
    /// The conversation its agent last named (`SessionInfo.conversationId`): read once its tab is closed, and never taken
    /// for the first worker's (`TaskItem.firstWorkerConversation`).
    public var conversation: String?
    /// More work on the task, or a review of its branch head (`open_tab`'s `role`). Work, its default, is left out of the
    /// save.
    @OmittedWhenDefault<SavedDefaults.Work> public var role: TabRole

    public init(key: String, agent: AgentKind, model: String, reasoning: String?, modelReason: String, brief: String,
                agentPinned: Bool = false, launch: LaunchAttempt, sessionId: String? = nil, failure: String? = nil,
                conversation: String? = nil, role: TabRole = .work) {
        self.key = key; self.agent = agent; self.model = model; self.reasoning = reasoning; self.modelReason = modelReason
        self.brief = brief; self.agentPinned = agentPinned; self.launch = launch; self.sessionId = sessionId; self.failure = failure
        self.conversation = conversation; self.role = role
    }
}

public struct PeopleReview: Codable, Equatable, Sendable {
    public var reviewers: [String]
    public var threads: [String: Bool]
    /// Each thread's last note as `ReviewWatcher.signature` writes it, by the thread's id.
    public var notes: [String: String]
    public var approvals: [String]
    public var ended: Bool
    public var startedAt: Date?

    public init(reviewers: [String] = [], threads: [String: Bool] = [:], notes: [String: String] = [:], approvals: [String] = [],
                ended: Bool = false, startedAt: Date? = nil) {
        self.reviewers = reviewers; self.threads = threads; self.notes = notes; self.approvals = approvals; self.ended = ended
        self.startedAt = startedAt
    }


}

public enum ClosingWait: String, Codable, Sendable, LocalizedError {
    case turn, agentTurn, helper

    public var text: String {
        switch self {
        case .turn: "Waiting for your turn to end"
        case .agentTurn: "Waiting for its turn to end"
        case .helper: "Waiting for the helper"
        }
    }

    public var errorDescription: String? { text }
}

public struct LaunchRequest: Codable, Equatable, Sendable {
    public var model: String?
    public var reasoning: String?
    public init(model: String?, reasoning: String?) { self.model = model; self.reasoning = reasoning }
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

    /// The snag as an AiTerm task's prompt: a line with nothing to say (no task, no evidence) is left out.
    public func fixTask(broadcast: String, runId: UUID) -> String {
        var seen = "Seen in broadcast \"\(broadcast)\" (\(runId.uuidString))"
        if let taskKey { seen += ", task \(taskKey)" + (branch.map { " on \($0)" } ?? "") }
        seen += ", AiTerm \(appVersion), \(ISO8601DateFormatter().string(from: at))."
        var lines = ["Fix in AiTerm: \(title)", "", seen, "",
                     "What AiTerm showed: \(showed)", "What was true: \(actual)", "How the Operator got unstuck: \(workaround)"]
        if let evidence = evidence?.trimmingCharacters(in: .whitespacesAndNewlines), !evidence.isEmpty {
            lines += ["Evidence:", evidence]
        }
        lines += ["", "Make AiTerm show what was true here, so the Operator doesn't have to work around it."]
        return lines.joined(separator: "\n")
    }
}

public struct ThreadCritique: Codable, Equatable, Sendable {
    public var thread: String
    public var note: String
    public var head: String?
    public var critique: String
    public var at: Date
    public init(thread: String, note: String, head: String?, critique: String, at: Date) {
        self.thread = thread; self.note = note; self.head = head; self.critique = critique; self.at = at
    }
}

public enum ChallengeStage: String, Codable, CaseIterable, Sendable { case running, ready, delivered, unchallenged, acted }

public enum ChallengeKind: String, Codable, Sendable { case critique, veto }

public struct ChallengeRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var tool: String
    /// A critique, or a veto; a record saved before vetoes is a critique.
    @Defaulted<SavedDefaults.Critique> public var kind: ChallengeKind
    public var stage: ChallengeStage
    /// The Oracle's critique, once it gave one; for a veto, the Oracle's reason.
    public var critique: String?
    /// A veto's answer once the Oracle gave one: true only for its yes.
    public var approved: Bool?
    /// The challenged call's arguments as canonical JSON, as `actedArguments`: a veto's yes acts only for these.
    public var askedArguments: String?
    /// A finish_task's veto, on a merge or a push past the hook (`noVerify`): the commit accepted when the Oracle was
    /// asked. Its yes holds for that commit only.
    public var askedSHA: String?
    /// Acceptance and required-check inputs used by this veto; refreshed evidence cannot reuse its verdict.
    /// For a relay round, the worker's question the Oracle read: its verdict judges no other question.
    public var askedEvidence: String?
    /// A finish_task's veto: whether the Oracle was asked about the merge's conditions, alone or with a push past the
    /// hook. False for one asked about the hook alone, whose yes is no merge's. Nil on a record saved before `noVerify`,
    /// when every finish_task veto was a merge's (`asksMerge`).
    public var askedMerge: Bool?
    /// Why the act proceeded unchallenged: the Oracle missing, failed or too slow.
    public var unchallengedReason: String?
    /// The acting call's arguments as canonical JSON, `challengeId` and `challengeReply` left out:
    /// a repeat is the same call when these are the same.
    public var actedArguments: String?
    /// The acting call's answer, as the JSON the operator read.
    public var result: String?
    public var askedAt: Date
    /// A relay's Oracle round, from 1 (`relay_question`, Agreed first); nil for any other challenge.
    public var round: Int?
    /// A relay's round answered: the Operator's reply to its critique, which the next round reads. Nil otherwise.
    public var reply: String?

    public init(id: String, tool: String, kind: ChallengeKind = .critique, stage: ChallengeStage = .running, critique: String? = nil,
                approved: Bool? = nil, askedArguments: String? = nil, askedSHA: String? = nil, unchallengedReason: String? = nil,
                actedArguments: String? = nil, result: String? = nil, askedAt: Date, askedMerge: Bool? = nil, askedEvidence: String? = nil,
                round: Int? = nil) {
        self.id = id; self.tool = tool; self.kind = kind; self.stage = stage; self.critique = critique; self.approved = approved
        self.askedArguments = askedArguments; self.askedSHA = askedSHA; self.askedMerge = askedMerge
        self.unchallengedReason = unchallengedReason; self.actedArguments = actedArguments; self.result = result
        self.askedAt = askedAt; self.askedEvidence = askedEvidence; self.round = round
    }

    /// Whether a finish_task's yes is a merge's (`askedMerge`).
    public var asksMerge: Bool { askedMerge ?? (askedSHA != nil) }

    /// What the record is, read from its tool, kind and round and never saved: a critique the Operator answers or acts
    /// on, a veto only a yes lets act, or one of a relayed question's Oracle rounds, from 1 (a round saved before rounds
    /// were numbered is the first).
    public enum Role: Equatable, Sendable { case critique, veto, relayRound(Int) }



    /// A relay's round (`role`); nil for any other record.
}

public struct PausedWorker: Codable, Hashable, Sendable {
    public var task: UUID
    public var tab: String?
    public var ownership: Int

    public init(task: UUID, tab: String?, ownership: Int) {
        self.task = task; self.tab = tab; self.ownership = ownership
    }
}
