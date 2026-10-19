import Foundation

// What `state.json` keeps of the Operator's broadcasts and their tasks. These types sit beside
// `Models.swift`, not in `Operators/`, because `AppState` and `TaskItem` hold them: the files
// directly in Core are the bottom layer and name no folder's types (`CoreFoldersTests`), while
// the engines in `Operators/` name these freely. Everything here is plain data; what may change
// it, and when, is the engines' (`OperatedTransitions`, `PlanRevision`, `RunScheduler`).

/// Where an operation stands (spec §9). `paused` and `stopped` are only ever yours.
public enum OperatorRunState: String, Codable, Sendable { case planning, active, paused, operatorOffline, complete, stopped }

/// Where a task's work ends, from the plan (spec §5): a commit in its worktree, a draft MR, a merge
/// through the request, or a local merge into the default branch with no request and no push. AiTerm's
/// `finish_task` carries each out, never the agent.
public enum TaskEnd: String, Codable, CaseIterable, Sendable { case commit, draftMR, merge, mergeLocal }

/// A task's workflow state (spec §8), separate from its session's live status.
public enum OperatedState: String, Codable, CaseIterable, Sendable {
    case planned, queued, working, inReview, blocked, failed, accepted, noChange, published, stopped

    /// Not yet ended: what Stop can still stop. `inReview` waits on a review of its request.
    public var isOpen: Bool { [.planned, .queued, .working, .inReview, .blocked, .failed].contains(self) }
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

/// What `finish_task` has done of a task's end, step by step (spec §6, §11). Each step is recorded,
/// and saved, as it completes, so a repeat — after a lost reply, a crash, a restart — resumes at the
/// next one and never pushes or opens twice.
public struct TaskPublication: Codable, Equatable, Sendable {
    private var preservedFields = PreservedFields()
    /// The commit pushed to the task's own branch on origin: the accepted one.
    public var pushedSHA: String?
    /// The merge or pull request opened for it, and its number on its host.
    public var mergeRequestURL: String?
    public var mergeRequestNumber: Int?
    /// The branch the request targets: the default branch, or a stacked task's parent's — until the
    /// parent merges and a `merge` end retargets it.
    public var targetBranch: String?
    /// A `merge` end: when AiTerm began waiting for the host to call it mergeable — the start of the
    /// bounded wait (`OperatorTiming.mergeWait`).
    public var waitingSince: Date?
    /// A `merge` end: when the host was first read calling it mergeable at the accepted commit. It is
    /// merged only on a later read, `OperatorTiming.mergePoll` on, that still says so: a pipeline may
    /// not have registered yet. Cleared by every read that does not.
    public var readySince: Date?
    /// A `merge` end: merged at the accepted commit, as `mergedSHA` — by AiTerm, or on the host before
    /// AiTerm's answer came. A request the host merged with another head is not: `mergedSHA` and
    /// `mergedHead` say what happened, `merged` stays false and nothing stacked on it merges.
    public var merged: Bool
    public var mergedSHA: String?
    /// The request's head commit the host merged, as the host reported it.
    public var mergedHead: String?
    /// Why the host will not merge it without someone acting — a failed pipeline, conflicts — or why
    /// the wait ended. Cleared by the operator's next `finish_task`.
    public var problem: String?

    public init(pushedSHA: String? = nil, mergeRequestURL: String? = nil, mergeRequestNumber: Int? = nil,
                targetBranch: String? = nil, waitingSince: Date? = nil, readySince: Date? = nil, merged: Bool = false,
                mergedSHA: String? = nil, mergedHead: String? = nil, problem: String? = nil) {
        self.pushedSHA = pushedSHA; self.mergeRequestURL = mergeRequestURL; self.mergeRequestNumber = mergeRequestNumber
        self.targetBranch = targetBranch; self.waitingSince = waitingSince; self.readySince = readySince; self.merged = merged
        self.mergedSHA = mergedSHA; self.mergedHead = mergedHead; self.problem = problem
    }

    private enum CodingKeys: String, CodingKey {
        case pushedSHA, mergeRequestURL, mergeRequestNumber, targetBranch, waitingSince, readySince, merged, mergedSHA, mergedHead, problem
    }

    /// Every field may be missing: a publication saved before the merge steps reads as not merged.
    /// Keys this build does not know are preserved.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preservedFields = try PreservedFields(decoder, known: CodingKeys.self)
        pushedSHA = try c.decodeIfPresent(String.self, forKey: .pushedSHA)
        mergeRequestURL = try c.decodeIfPresent(String.self, forKey: .mergeRequestURL)
        mergeRequestNumber = try c.decodeIfPresent(Int.self, forKey: .mergeRequestNumber)
        targetBranch = try c.decodeIfPresent(String.self, forKey: .targetBranch)
        waitingSince = try c.decodeIfPresent(Date.self, forKey: .waitingSince)
        readySince = try c.decodeIfPresent(Date.self, forKey: .readySince)
        merged = try c.decodeIfPresent(Bool.self, forKey: .merged) ?? false
        mergedSHA = try c.decodeIfPresent(String.self, forKey: .mergedSHA)
        mergedHead = try c.decodeIfPresent(String.self, forKey: .mergedHead)
        problem = try c.decodeIfPresent(String.self, forKey: .problem)
    }

    public func encode(to encoder: Encoder) throws {
        try preservedFields.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(pushedSHA, forKey: .pushedSHA)
        try c.encodeIfPresent(mergeRequestURL, forKey: .mergeRequestURL)
        try c.encodeIfPresent(mergeRequestNumber, forKey: .mergeRequestNumber)
        try c.encodeIfPresent(targetBranch, forKey: .targetBranch)
        try c.encodeIfPresent(waitingSince, forKey: .waitingSince)
        try c.encodeIfPresent(readySince, forKey: .readySince)
        try c.encode(merged, forKey: .merged)
        try c.encodeIfPresent(mergedSHA, forKey: .mergedSHA)
        try c.encodeIfPresent(mergedHead, forKey: .mergedHead)
        try c.encodeIfPresent(problem, forKey: .problem)
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
    private var preservedFields = PreservedFields()
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
    /// The state it was blocked from (`working` or `queued`), which resume returns it to; nil for a
    /// task not blocked, or blocked by an older build.
    public var blockedFrom: OperatedState?
    /// What the last failed attempt reported (`fail_task`): kept through a retry and its start, so the
    /// retried worker is told what failed; cleared when the task is accepted or ends with no change.
    public var lastFailure: String?
    public var flags: Set<OperatedFlag>
    /// Why the Operator chose the task's model, in its words.
    public var modelReason: String?
    /// The prompt or the Instructions named the task's agent: it starts on that agent whatever its use.
    public var agentPinned: Bool
    /// The id of the AiTerm issue blocking it, while one does.
    public var problem: String?

    public init(runId: UUID, key: String, state: OperatedState = .planned, end: TaskEnd = .commit, brief: String,
                dependsOn: [TaskDependency] = [], stackedOn: UUID? = nil, revision: Int, firstRevision: Int? = nil,
                acceptance: TaskAcceptance? = nil, publication: TaskPublication? = nil, takenOver: Bool = false,
                ownership: Int = 0, launch: LaunchAttempt? = nil, retriesUsed: Int = 0, runtimeUsed: TimeInterval = 0,
                blockedReason: String? = nil, blockedFrom: OperatedState? = nil, flags: Set<OperatedFlag> = [],
                lastFailure: String? = nil, modelReason: String? = nil, agentPinned: Bool = false, problem: String? = nil) {
        self.runId = runId; self.key = key; self.state = state; self.end = end; self.brief = brief
        self.dependsOn = dependsOn; self.stackedOn = stackedOn; self.revision = revision
        self.firstRevision = firstRevision ?? revision
        self.acceptance = acceptance; self.publication = publication; self.takenOver = takenOver
        self.ownership = ownership; self.launch = launch; self.retriesUsed = retriesUsed; self.runtimeUsed = runtimeUsed
        self.blockedReason = blockedReason; self.blockedFrom = blockedFrom; self.flags = flags
        self.lastFailure = lastFailure
        self.modelReason = modelReason; self.agentPinned = agentPinned; self.problem = problem
    }

    /// Whether a worker was ever launched for it: what makes it "started" for the plan and for
    /// the M1 re-accept rule, whatever its state is now.
    public var started: Bool { launch != nil }

    private enum CodingKeys: String, CodingKey {
        case runId, key, state, end, brief, dependsOn, stackedOn, revision, firstRevision, acceptance, publication
        case takenOver, ownership, launch, retriesUsed, runtimeUsed, blockedReason, blockedFrom, flags, lastFailure
        case modelReason, agentPinned, problem
    }

    /// Synthesised but for `flags`: a flag this build does not know is dropped, not a failed load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preservedFields = try PreservedFields(decoder, known: CodingKeys.self)
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
        blockedFrom = try c.decodeIfPresent(OperatedState.self, forKey: .blockedFrom)
        lastFailure = try c.decodeIfPresent(String.self, forKey: .lastFailure)
        flags = Set((try c.decodeIfPresent([String].self, forKey: .flags) ?? []).compactMap(OperatedFlag.init(rawValue:)))
        modelReason = try c.decodeIfPresent(String.self, forKey: .modelReason)
        agentPinned = try c.decodeIfPresent(Bool.self, forKey: .agentPinned) ?? false
        problem = try c.decodeIfPresent(String.self, forKey: .problem)
    }

    public func encode(to encoder: Encoder) throws {
        try preservedFields.encode(to: encoder)
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
        try c.encodeIfPresent(blockedFrom, forKey: .blockedFrom)
        try c.encodeIfPresent(lastFailure, forKey: .lastFailure)
        // Sorted, so the file does not change on a resave of the same flags.
        try c.encode(flags.map(\.rawValue).sorted(), forKey: .flags)
        try c.encodeIfPresent(modelReason, forKey: .modelReason)
        try c.encode(agentPinned, forKey: .agentPinned)
        try c.encodeIfPresent(problem, forKey: .problem)
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

/// One line of the decisions log; `challenge` is the Oracle's critique and the reply, and `objection`
/// the Oracle's, when it disagreed and the Operator decided anyway.
public struct OperatorDecision: Codable, Equatable, Sendable {
    public var key: String
    public var text: String
    public var task: UUID?
    public var at: Date
    public var challenge: String?
    public var objection: String?
    public init(key: String, text: String, task: UUID?, at: Date, challenge: String? = nil, objection: String? = nil) {
        self.key = key; self.text = text; self.task = task; self.at = at; self.challenge = challenge; self.objection = objection
    }
}

/// Something the Operator found that the brief did not ask for (spec §4.1): never worked on, listed in
/// the debrief, and filed as `ticket` when the Jira slice is on.
public struct OffBriefFind: Codable, Equatable, Sendable {
    public var key: String
    public var title: String
    public var why: String
    public var ticket: String?
    public init(key: String, title: String, why: String, ticket: String? = nil) {
        self.key = key; self.title = title; self.why = why; self.ticket = ticket
    }
}

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

/// A broadcast, "run" in code (spec §4, §5). The app is its only writer.
public struct OperatorRun: Codable, Equatable, Sendable, Identifiable {
    private var preservedFields = PreservedFields()
    public var id: UUID
    public var name: String
    /// Settings › Operator as it was when the broadcast started: a change there applies to the next one.
    public var profile: OperatorProfile
    /// The run's scope: every task belongs to one of these projects.
    public var projectIds: [UUID]
    /// The Jira projects its tickets are in, by key.
    public var jiraProjectKeys: [String]
    /// What you asked for, how its work is reviewed, and what done looks like.
    public var prompt: String, review: String?, done: String?
    public var state: OperatorRunState
    /// `.paused` or `.stopped` when you said so; persisted, and never undone by reconciliation.
    public var intent: OperatorRunState?
    /// The last submitted plan revision, 0 while none is. New and changed tasks go into the open
    /// one, `openRevision`; `submit_plan` closes it (`PlanRevision`). A plan waits for you while
    /// `planRevision > (approvedRevision ?? 0)`.
    public var planRevision: Int
    /// Round 1's plan approval, kept only until plans release at once (the plan's Task 2).
    public var approvedRevision: Int?
    /// How many tasks the first submitted plan had: what the backlog's growth is measured against.
    public var firstPlanSize: Int?
    public var questions: [OperatorQuestion], decisions: [OperatorDecision]
    /// The off-brief finds, for the debrief; and what the slices kept the Operator from doing.
    public var finds: [OffBriefFind], leftForYou: [String]
    /// The Oracle's challenges of this run's calls, the ones acted on kept with their answer.
    public var challenges: [ChallengeRecord]
    /// The Operator's Claude conversation, for `claude --resume`.
    public var operatorConversation: String?, operatorWindowId: String?, operatorSessionId: String?
    public var createdAt: Date

    /// `projectIds` defaults to none: a run made in a test or a fixture that never reads its scope.
    public init(id: UUID, name: String, profile: OperatorProfile, projectIds: [UUID] = [], jiraProjectKeys: [String] = [],
                prompt: String, review: String? = nil, done: String? = nil, state: OperatorRunState = .planning,
                intent: OperatorRunState? = nil, planRevision: Int = 0, approvedRevision: Int? = nil, firstPlanSize: Int? = nil,
                questions: [OperatorQuestion] = [], decisions: [OperatorDecision] = [], finds: [OffBriefFind] = [],
                leftForYou: [String] = [], operatorConversation: String? = nil, operatorWindowId: String? = nil,
                operatorSessionId: String? = nil, challenges: [ChallengeRecord] = [], createdAt: Date) {
        self.id = id; self.name = name; self.profile = profile; self.projectIds = projectIds; self.jiraProjectKeys = jiraProjectKeys
        self.prompt = prompt; self.review = review; self.done = done; self.state = state; self.intent = intent
        self.planRevision = planRevision; self.approvedRevision = approvedRevision; self.firstPlanSize = firstPlanSize
        self.questions = questions; self.decisions = decisions; self.finds = finds; self.leftForYou = leftForYou
        self.operatorConversation = operatorConversation; self.operatorWindowId = operatorWindowId
        self.operatorSessionId = operatorSessionId; self.challenges = challenges; self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, profile, projectIds, jiraProjectKeys, prompt, review, done, state, intent, planRevision, approvedRevision
        case firstPlanSize, questions, decisions, finds, leftForYou, challenges, operatorConversation, operatorWindowId
        case operatorSessionId, createdAt
    }

    /// The lists may be missing and read as empty. A run without a profile or a prompt (round 1's,
    /// with its persona) fails, and `AppState` keeps it whole without showing it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preservedFields = try PreservedFields(decoder, known: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        profile = try c.decode(OperatorProfile.self, forKey: .profile)
        projectIds = try c.decodeIfPresent([UUID].self, forKey: .projectIds) ?? []
        jiraProjectKeys = try c.decodeIfPresent([String].self, forKey: .jiraProjectKeys) ?? []
        prompt = try c.decode(String.self, forKey: .prompt)
        review = try c.decodeIfPresent(String.self, forKey: .review)
        done = try c.decodeIfPresent(String.self, forKey: .done)
        state = try c.decode(OperatorRunState.self, forKey: .state)
        intent = try c.decodeIfPresent(OperatorRunState.self, forKey: .intent)
        planRevision = try c.decode(Int.self, forKey: .planRevision)
        approvedRevision = try c.decodeIfPresent(Int.self, forKey: .approvedRevision)
        firstPlanSize = try c.decodeIfPresent(Int.self, forKey: .firstPlanSize)
        questions = try c.decodeIfPresent([OperatorQuestion].self, forKey: .questions) ?? []
        decisions = try c.decodeIfPresent([OperatorDecision].self, forKey: .decisions) ?? []
        finds = try c.decodeIfPresent([OffBriefFind].self, forKey: .finds) ?? []
        leftForYou = try c.decodeIfPresent([String].self, forKey: .leftForYou) ?? []
        challenges = try c.decodeIfPresent([ChallengeRecord].self, forKey: .challenges) ?? []
        operatorConversation = try c.decodeIfPresent(String.self, forKey: .operatorConversation)
        operatorWindowId = try c.decodeIfPresent(String.self, forKey: .operatorWindowId)
        operatorSessionId = try c.decodeIfPresent(String.self, forKey: .operatorSessionId)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    /// The revision `create_task` and `update_task` add to: the one after the last submitted.
    public var openRevision: Int { planRevision + 1 }

    public func encode(to encoder: Encoder) throws {
        try preservedFields.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(profile, forKey: .profile)
        try c.encode(projectIds, forKey: .projectIds)
        try c.encode(jiraProjectKeys, forKey: .jiraProjectKeys)
        try c.encode(prompt, forKey: .prompt)
        try c.encodeIfPresent(review, forKey: .review)
        try c.encodeIfPresent(done, forKey: .done)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(intent, forKey: .intent)
        try c.encode(planRevision, forKey: .planRevision)
        try c.encodeIfPresent(approvedRevision, forKey: .approvedRevision)
        try c.encodeIfPresent(firstPlanSize, forKey: .firstPlanSize)
        try c.encode(questions, forKey: .questions)
        try c.encode(decisions, forKey: .decisions)
        try c.encode(finds, forKey: .finds)
        try c.encode(leftForYou, forKey: .leftForYou)
        try c.encode(challenges, forKey: .challenges)
        try c.encodeIfPresent(operatorConversation, forKey: .operatorConversation)
        try c.encodeIfPresent(operatorWindowId, forKey: .operatorWindowId)
        try c.encodeIfPresent(operatorSessionId, forKey: .operatorSessionId)
        try c.encode(createdAt, forKey: .createdAt)
    }
}
