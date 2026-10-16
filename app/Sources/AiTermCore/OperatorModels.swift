import Foundation

// What `state.json` keeps of operators and their operations (spec §5.1). These types sit beside
// `Models.swift`, not in `Operators/`, because `AppState` and `TaskItem` hold them: the files
// directly in Core are the bottom layer and name no folder's types (`CoreFoldersTests`), while
// the engines in `Operators/` name these freely. Everything here is plain data; what may change
// it, and when, is the engines' (`OperatedTransitions`, `PlanRevision`, `RunScheduler`).

/// How much an operator does without you (spec §4.1): the plan gate, the workers' permission
/// mode, which questions it asks, and when AiTerm notifies you of them.
public enum Autonomy: String, Codable, CaseIterable, Sendable {
    case askFirst, routine, trusted, handsOff

    /// Whether you approve each plan revision before its tasks start: on at Ask first and Routine.
    public var gatesPlans: Bool { self == .askFirst || self == .routine }
}

/// How hard another model challenges the operator before an act takes effect (spec §4.4).
public enum SecondOpinionLevel: String, Codable, CaseIterable, Sendable { case noSelfDoubt, healthyDoubt, impostor }

/// The one agent, model and effort that challenges an operator; `level` says how often.
public struct SecondOpinion: Codable, Equatable, Sendable {
    public var level: SecondOpinionLevel
    public var agent: AgentKind
    public var model: String
    public var effort: String?
    public init(level: SecondOpinionLevel, agent: AgentKind, model: String, effort: String?) {
        self.level = level; self.agent = agent; self.model = model; self.effort = effort
    }

    /// A new operator's: Healthy doubt from another model family than the Claude lead (spec §4.4).
    public static let standard = SecondOpinion(level: .healthyDoubt, agent: .codex, model: "gpt-6-astra", effort: "medium")
}

/// What one task of an operation may use before AiTerm blocks it and asks you (spec §8).
public struct OperatorLimits: Codable, Equatable, Sendable {
    /// Relaunches of a failed task.
    public var retries: Int = 2
    /// Per task, counted while it works — not while it waits on you.
    public var runtimeMinutes: Int = 90
    public init(retries: Int = 2, runtimeMinutes: Int = 90) { self.retries = retries; self.runtimeMinutes = runtimeMinutes }
}

/// An operator: who works, in every operation it runs (spec §4.0). Its file is
/// `operators/<handle>.md` (`OperatorFile`); an operation keeps a snapshot of it from its start.
public struct OperatorPersona: Codable, Equatable, Sendable, Identifiable {
    /// The handle is the file's name, unique in the library, so it is the identity.
    public var id: String { handle }
    public var name: String, handle: String, model: String, effort: String?
    public var secondOpinion: SecondOpinion, autonomy: Autonomy
    /// Added to the fixed ask-first list (spec §4.2); nothing removes an entry of that list.
    public var alwaysAsk: [String], limits: OperatorLimits
    /// The "## Persona" body.
    public var persona: String
    /// The "## Lessons" bullets, one sentence each, in the order they were kept.
    public var lessons: [String]

    public init(name: String, handle: String, model: String, effort: String?, secondOpinion: SecondOpinion,
                autonomy: Autonomy, alwaysAsk: [String] = [], limits: OperatorLimits = OperatorLimits(),
                persona: String, lessons: [String] = []) {
        self.name = name; self.handle = handle; self.model = model; self.effort = effort
        self.secondOpinion = secondOpinion; self.autonomy = autonomy
        self.alwaysAsk = alwaysAsk; self.limits = limits; self.persona = persona; self.lessons = lessons
    }
}

/// Where an operation stands (spec §9). `paused` and `stopped` are only ever yours.
public enum OperatorRunState: String, Codable, Sendable { case planning, active, paused, operatorOffline, complete, stopped }

/// Where a task's work ends, from the plan (spec §4.0.1 and the 16 Oct change): a commit in its
/// worktree, a draft MR, or a merge that AiTerm's `finish_task` carries out — never the agent.
public enum TaskEnd: String, Codable, CaseIterable, Sendable { case commit, draftMR, merge }

/// A task's workflow state (spec §8), separate from its session's live status.
public enum OperatedState: String, Codable, CaseIterable, Sendable {
    case planned, queued, working, blocked, failed, accepted, noChange, published, stopped

    /// Not yet ended: what Stop can still stop.
    public var isOpen: Bool { [.planned, .queued, .working, .blocked, .failed].contains(self) }
}

/// `order`: start after the parent ends well. `code`: also branch from the parent's accepted SHA.
public enum DependencyKind: String, Codable, Sendable { case order, code }

public struct TaskDependency: Codable, Equatable, Hashable, Sendable {
    public var task: UUID
    public var kind: DependencyKind
    public init(task: UUID, kind: DependencyKind) { self.task = task; self.kind = kind }
}

/// What the operator attested when it accepted a task: the SHA on the task's branch, the SHAs of
/// the parents it was built on, and the worker's check output (spec §3, "accepted means
/// operator-attested").
public struct TaskAcceptance: Codable, Equatable, Sendable {
    public var resultSHA: String
    public var prerequisiteSHAs: [String]
    public var checkOutput: String
    public var note: String?
    public var at: Date
    public init(resultSHA: String, prerequisiteSHAs: [String], checkOutput: String, note: String?, at: Date) {
        self.resultSHA = resultSHA; self.prerequisiteSHAs = prerequisiteSHAs; self.checkOutput = checkOutput
        self.note = note; self.at = at
    }
}

/// Each step `finish_task` has carried out (M3), so calling it again resumes at the next one.
public struct TaskPublication: Codable, Equatable, Sendable {
    public var pushedSHA: String?
    public var mergeRequestURL: String?
    public init(pushedSHA: String? = nil, mergeRequestURL: String? = nil) {
        self.pushedSHA = pushedSHA; self.mergeRequestURL = mergeRequestURL
    }
}

/// A worker launch AiTerm asked for, saved before the daemon is asked for its window (spec §11):
/// after a crash, reconciliation adopts a session tagged with this attempt instead of launching twice.
public struct LaunchAttempt: Codable, Equatable, Sendable {
    public var number: Int
    public var requestedAt: Date
    /// When its worker's window was first seen — recorded by AiTerm, nil while it may still be
    /// opening. A launch that showed a window is never launched again: a worker whose window you
    /// closed comes back on your click, its conversation resumed, never as a second worker.
    public var openedAt: Date?
    public init(number: Int, requestedAt: Date, openedAt: Date? = nil) {
        self.number = number; self.requestedAt = requestedAt; self.openedAt = openedAt
    }
}

/// A flag on top of a task's state (spec §8). Advisory, so one a newer build wrote is dropped on
/// read rather than failing the task (`OperatedTask.init(from:)`).
public enum OperatedFlag: String, Codable, CaseIterable, Sendable { case possiblyStalled, uncertain, upstreamReplaced, waitingOnYou }

/// Everything an operator adds to a task. `TaskItem.operated` — nil for every task you made yourself.
public struct OperatedTask: Codable, Equatable, Sendable {
    public var runId: UUID
    /// The operator's idempotency key: `create_task` with a key the run has returns that task.
    public var key: String
    public var state: OperatedState
    public var end: TaskEnd
    public var brief: String
    public var dependsOn: [TaskDependency]
    /// The `code` parent, whose accepted SHA the worktree branches from.
    public var stackedOn: UUID?
    /// The plan revision that added or last changed it.
    public var revision: Int
    /// The plan revision that added it: a task whose `revision` is newer was changed since, which
    /// the plan you approve shows apart from what it adds (`PlanRevision.pending`).
    public var firstRevision: Int
    public var acceptance: TaskAcceptance?, publication: TaskPublication?
    /// While true, the operator's tools refuse the task (spec §8, Take over / Hand back).
    public var takenOver: Bool
    /// The generation a takeover increments: a delivery begun under an older one never finishes.
    public var ownership: Int
    public var launch: LaunchAttempt?
    public var retriesUsed: Int
    /// Seconds worked, not counting time waiting on you.
    public var runtimeUsed: TimeInterval
    public var blockedReason: String?
    public var flags: Set<OperatedFlag>

    public init(runId: UUID, key: String, state: OperatedState = .planned, end: TaskEnd = .commit, brief: String,
                dependsOn: [TaskDependency] = [], stackedOn: UUID? = nil, revision: Int, firstRevision: Int? = nil,
                acceptance: TaskAcceptance? = nil, publication: TaskPublication? = nil, takenOver: Bool = false,
                ownership: Int = 0, launch: LaunchAttempt? = nil, retriesUsed: Int = 0, runtimeUsed: TimeInterval = 0,
                blockedReason: String? = nil, flags: Set<OperatedFlag> = []) {
        self.runId = runId; self.key = key; self.state = state; self.end = end; self.brief = brief
        self.dependsOn = dependsOn; self.stackedOn = stackedOn; self.revision = revision
        self.firstRevision = firstRevision ?? revision
        self.acceptance = acceptance; self.publication = publication; self.takenOver = takenOver
        self.ownership = ownership; self.launch = launch; self.retriesUsed = retriesUsed; self.runtimeUsed = runtimeUsed
        self.blockedReason = blockedReason; self.flags = flags
    }

    /// Whether a worker was ever launched for it: what makes it "started" for the plan and for
    /// the M1 re-accept rule, whatever its state is now.
    public var started: Bool { launch != nil }

    private enum CodingKeys: String, CodingKey {
        case runId, key, state, end, brief, dependsOn, stackedOn, revision, firstRevision, acceptance, publication
        case takenOver, ownership, launch, retriesUsed, runtimeUsed, blockedReason, flags
    }

    /// Synthesised but for `flags`: a flag this build does not know is dropped, not a failed load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runId = try c.decode(UUID.self, forKey: .runId)
        key = try c.decode(String.self, forKey: .key)
        state = try c.decode(OperatedState.self, forKey: .state)
        end = try c.decode(TaskEnd.self, forKey: .end)
        brief = try c.decode(String.self, forKey: .brief)
        dependsOn = try c.decodeIfPresent([TaskDependency].self, forKey: .dependsOn) ?? []
        stackedOn = try c.decodeIfPresent(UUID.self, forKey: .stackedOn)
        revision = try c.decode(Int.self, forKey: .revision)
        firstRevision = try c.decodeIfPresent(Int.self, forKey: .firstRevision) ?? revision
        acceptance = try c.decodeIfPresent(TaskAcceptance.self, forKey: .acceptance)
        publication = try c.decodeIfPresent(TaskPublication.self, forKey: .publication)
        takenOver = try c.decodeIfPresent(Bool.self, forKey: .takenOver) ?? false
        ownership = try c.decodeIfPresent(Int.self, forKey: .ownership) ?? 0
        launch = try c.decodeIfPresent(LaunchAttempt.self, forKey: .launch)
        retriesUsed = try c.decodeIfPresent(Int.self, forKey: .retriesUsed) ?? 0
        runtimeUsed = try c.decodeIfPresent(TimeInterval.self, forKey: .runtimeUsed) ?? 0
        blockedReason = try c.decodeIfPresent(String.self, forKey: .blockedReason)
        flags = Set((try c.decodeIfPresent([String].self, forKey: .flags) ?? []).compactMap(OperatedFlag.init(rawValue:)))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runId, forKey: .runId)
        try c.encode(key, forKey: .key)
        try c.encode(state, forKey: .state)
        try c.encode(end, forKey: .end)
        try c.encode(brief, forKey: .brief)
        try c.encode(dependsOn, forKey: .dependsOn)
        try c.encodeIfPresent(stackedOn, forKey: .stackedOn)
        try c.encode(revision, forKey: .revision)
        try c.encode(firstRevision, forKey: .firstRevision)
        try c.encodeIfPresent(acceptance, forKey: .acceptance)
        try c.encodeIfPresent(publication, forKey: .publication)
        try c.encode(takenOver, forKey: .takenOver)
        try c.encode(ownership, forKey: .ownership)
        try c.encodeIfPresent(launch, forKey: .launch)
        try c.encode(retriesUsed, forKey: .retriesUsed)
        try c.encode(runtimeUsed, forKey: .runtimeUsed)
        try c.encodeIfPresent(blockedReason, forKey: .blockedReason)
        // Sorted, so the file does not change on a resave of the same flags.
        try c.encode(flags.map(\.rawValue).sorted(), forKey: .flags)
    }
}

/// A question the operator opened with `ask_you`; `id` is its key. Open until `resolution`.
public struct OperatorQuestion: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var task: UUID?
    public var askedAt: Date
    public var resolution: String?
    public init(id: String, text: String, task: UUID?, askedAt: Date, resolution: String? = nil) {
        self.id = id; self.text = text; self.task = task; self.askedAt = askedAt; self.resolution = resolution
    }
}

/// One line of the decisions log; `challenge` is the second opinion's critique and the reply.
public struct OperatorDecision: Codable, Equatable, Sendable {
    public var key: String
    public var text: String
    public var task: UUID?
    public var at: Date
    public var challenge: String?
    public init(key: String, text: String, task: UUID?, at: Date, challenge: String? = nil) {
        self.key = key; self.text = text; self.task = task; self.at = at; self.challenge = challenge
    }
}

public enum LessonDecision: String, Codable, Sendable { case kept, dismissed }

/// Where a challenged tool call stands (spec §4.4): its second opinion running, its critique ready
/// but not yet read, read by the operator, unavailable — the act then proceeds unchallenged — or acted on.
public enum ChallengeStage: String, Codable, CaseIterable, Sendable { case running, ready, delivered, unchallenged, acted }

/// One challenged tool call, kept in its run (spec §4.4, §11): the call it challenged, what the
/// second opinion said, and — once a call with its id acted — that call and its answer. A repeat of
/// the acting call (its reply lost, AiTerm restarted) returns the recorded answer and acts no
/// further. `id` is the `challengeId` the operator calls again with.
public struct ChallengeRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var tool: String
    public var stage: ChallengeStage
    /// The second opinion's critique, once it gave one.
    public var critique: String?
    /// Why the act proceeded unchallenged: the second opinion missing, failed or too slow.
    public var unchallengedReason: String?
    /// The acting call's arguments as canonical JSON, `challengeId` and `challengeReply` left out:
    /// a repeat is the same call when these are the same.
    public var actedArguments: String?
    /// The acting call's answer, as the JSON the operator read.
    public var result: String?
    public var askedAt: Date

    public init(id: String, tool: String, stage: ChallengeStage = .running, critique: String? = nil,
                unchallengedReason: String? = nil, actedArguments: String? = nil, result: String? = nil, askedAt: Date) {
        self.id = id; self.tool = tool; self.stage = stage; self.critique = critique
        self.unchallengedReason = unchallengedReason; self.actedArguments = actedArguments; self.result = result
        self.askedAt = askedAt
    }
}

/// A lesson the operator offered (spec §4.5); only you keep it.
public struct ProposedLesson: Codable, Equatable, Sendable {
    public var key: String
    public var lesson: String
    public var because: String
    public var decided: LessonDecision?
    public init(key: String, lesson: String, because: String, decided: LessonDecision? = nil) {
        self.key = key; self.lesson = lesson; self.because = because; self.decided = decided
    }
}

/// An operation — "run" in code (spec §4.0.1, §5.1). The app is its only writer.
public struct OperatorRun: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// The operator as it was when the operation started: editing the operator changes the next one.
    public var persona: OperatorPersona
    /// The run's scope (spec §5.3): every task belongs to one of these projects.
    public var projectIds: [UUID]
    public var brief: String, doneWhen: String?
    public var state: OperatorRunState
    /// `.paused` or `.stopped` when you said so; persisted, and never undone by reconciliation.
    public var intent: OperatorRunState?
    /// The last submitted plan revision, 0 while none is. New and changed tasks go into the open
    /// one, `openRevision`; `submit_plan` closes it (`PlanRevision`). In a gated run a plan waits
    /// for you while `planRevision > (approvedRevision ?? 0)`.
    public var planRevision: Int
    public var approvedRevision: Int?
    public var questions: [OperatorQuestion], decisions: [OperatorDecision], lessons: [ProposedLesson]
    /// The operator's Claude conversation, for `claude --resume`.
    public var operatorConversation: String?, operatorWindowId: String?, operatorSessionId: String?
    /// The second opinion's challenges of this run's calls, the ones acted on kept with their answer.
    public var challenges: [ChallengeRecord]
    public var createdAt: Date

    /// `projectIds` defaults to none: a run made in a test or a fixture that never reads its scope.
    public init(id: UUID, name: String, persona: OperatorPersona, projectIds: [UUID] = [], brief: String, doneWhen: String?,
                state: OperatorRunState = .planning, intent: OperatorRunState? = nil, planRevision: Int = 0,
                approvedRevision: Int? = nil, questions: [OperatorQuestion] = [], decisions: [OperatorDecision] = [],
                lessons: [ProposedLesson] = [], operatorConversation: String? = nil, operatorWindowId: String? = nil,
                operatorSessionId: String? = nil, challenges: [ChallengeRecord] = [], createdAt: Date) {
        self.id = id; self.name = name; self.persona = persona; self.projectIds = projectIds
        self.brief = brief; self.doneWhen = doneWhen; self.state = state; self.intent = intent
        self.planRevision = planRevision; self.approvedRevision = approvedRevision
        self.questions = questions; self.decisions = decisions; self.lessons = lessons
        self.operatorConversation = operatorConversation; self.operatorWindowId = operatorWindowId
        self.operatorSessionId = operatorSessionId; self.challenges = challenges; self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, persona, projectIds, brief, doneWhen, state, intent, planRevision, approvedRevision
        case questions, decisions, lessons, operatorConversation, operatorWindowId, operatorSessionId, challenges, createdAt
    }

    /// Synthesised but for `challenges`, which a run saved before them reads as none.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        persona = try c.decode(OperatorPersona.self, forKey: .persona)
        projectIds = try c.decode([UUID].self, forKey: .projectIds)
        brief = try c.decode(String.self, forKey: .brief)
        doneWhen = try c.decodeIfPresent(String.self, forKey: .doneWhen)
        state = try c.decode(OperatorRunState.self, forKey: .state)
        intent = try c.decodeIfPresent(OperatorRunState.self, forKey: .intent)
        planRevision = try c.decode(Int.self, forKey: .planRevision)
        approvedRevision = try c.decodeIfPresent(Int.self, forKey: .approvedRevision)
        questions = try c.decode([OperatorQuestion].self, forKey: .questions)
        decisions = try c.decode([OperatorDecision].self, forKey: .decisions)
        lessons = try c.decode([ProposedLesson].self, forKey: .lessons)
        operatorConversation = try c.decodeIfPresent(String.self, forKey: .operatorConversation)
        operatorWindowId = try c.decodeIfPresent(String.self, forKey: .operatorWindowId)
        operatorSessionId = try c.decodeIfPresent(String.self, forKey: .operatorSessionId)
        challenges = try c.decodeIfPresent([ChallengeRecord].self, forKey: .challenges) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    /// The revision `create_task` and `update_task` add to: the one after the last submitted.
    public var openRevision: Int { planRevision + 1 }
}
