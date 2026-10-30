import Foundation

// Persisted Operator facts. Transition, planning and scheduling rules live beside these values.

/// Where a broadcast stands (spec §9). `paused` and `stopped` are only ever yours.
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
    /// The commit pushed to the task's own branch on origin: the accepted one.
    public var pushedSHA: String?
    /// Publication permanently left to the person for this broadcast.
    public var leftForYou: Bool = false
    public var waitingReason: String?
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
    /// The accepted commit `finish_task` found already in `targetBranch`, merged outside it (by hand, by a worker): the
    /// task is recorded as `merged` with it, and `mergedSHA` stays nil, since ancestry alone names no merge commit.
    public var landedSHA: String?
    /// The request's head commit the host merged, as the host reported it.
    public var mergedHead: String?
    /// Why the host will not merge it without someone acting — a failed pipeline, conflicts — or why
    /// the wait ended. Cleared by the operator's next `finish_task`.
    public var problem: String?
    /// The Merge slice with the Oracle on: the accepted commit the Oracle said yes for, that the conditions written in
    /// the Review and the Done hold. A merge goes ahead only while it is the commit accepted now.
    public var conditionsHeld: String?
    /// Required-check inputs the Oracle approved, alongside the commit. Old SHA-only approvals are refreshed.
    public var conditionsEvidence: String?
    /// The Oracle refused this merge; separate from a publication failure, cleared on the next finish_task.
    public var mergeRefusal: String?
    /// The repository the request was opened in, as its host and path (`MergeRequestPublishing.repository`). A review
    /// write or a merge goes ahead only while the project's origin still resolves to it: a request opened before
    /// AiTerm kept it is not acted on.
    public var repository: String?
    /// What the pre-push hook said when it last refused the push (`GitError.pushReason`), kept for the Oracle to judge a
    /// `finish_task` with `noVerify` by (spec §B); none until a push is refused, and cleared once one lands. It holds for
    /// the commit it refused, `lastPushFailureSHA`, only (`pushFailure(for:)`).
    public var lastPushFailure: String?
    public var lastPushFailureSHA: String?

    /// What the hook said refusing the push of `sha`: nil when the last refusal was of another commit, or none was.
    /// A commit accepted since was never run through the hook, so nothing is known yet to push it past.
    public func pushFailure(for sha: String?) -> String? {
        guard let sha, lastPushFailureSHA == sha else { return nil }
        return lastPushFailure
    }

    public init(pushedSHA: String? = nil, mergeRequestURL: String? = nil, mergeRequestNumber: Int? = nil,
                targetBranch: String? = nil, waitingSince: Date? = nil, readySince: Date? = nil, merged: Bool = false,
                mergedSHA: String? = nil, mergedHead: String? = nil, problem: String? = nil, conditionsHeld: String? = nil,
                repository: String? = nil, leftForYou: Bool = false, waitingReason: String? = nil, mergeRefusal: String? = nil,
                lastPushFailure: String? = nil, lastPushFailureSHA: String? = nil, landedSHA: String? = nil) {
        self.pushedSHA = pushedSHA; self.mergeRequestURL = mergeRequestURL; self.mergeRequestNumber = mergeRequestNumber
        self.targetBranch = targetBranch; self.waitingSince = waitingSince; self.readySince = readySince; self.merged = merged
        self.mergedSHA = mergedSHA; self.mergedHead = mergedHead; self.problem = problem; self.conditionsHeld = conditionsHeld
        self.mergeRefusal = mergeRefusal
        self.repository = repository; self.leftForYou = leftForYou; self.waitingReason = waitingReason
        self.lastPushFailure = lastPushFailure; self.lastPushFailureSHA = lastPushFailureSHA; self.landedSHA = landedSHA
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

/// A worker tab the Operator added to a running task (`open_tab`): another agent in the task's window, on its worktree
/// and branch. It is part of the task, which keeps one card and one branch and is accepted once. Saved before the
/// daemon is asked for it, as a task's `LaunchAttempt` is: the reconciler and a restart adopt the session tagged with
/// the task and this `key` (`SessionInfo.tabKey`) instead of opening a second one.
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
    /// More work on the task, or a review of its branch head (`open_tab`'s `role`).
    public var role: TabRole

    public init(key: String, agent: AgentKind, model: String, reasoning: String?, modelReason: String, brief: String,
                agentPinned: Bool = false, launch: LaunchAttempt, sessionId: String? = nil, failure: String? = nil,
                conversation: String? = nil, role: TabRole = .work) {
        self.key = key; self.agent = agent; self.model = model; self.reasoning = reasoning; self.modelReason = modelReason
        self.brief = brief; self.agentPinned = agentPinned; self.launch = launch; self.sessionId = sessionId; self.failure = failure
        self.conversation = conversation; self.role = role
    }

    private enum CodingKeys: String, CodingKey {
        case requestedLaunch
        case key, agent, model, reasoning, modelReason, brief, agentPinned, launch, sessionId, failure, conversation, role
    }

    /// Work tabs omit their default role in the current saved format.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        agent = try c.decode(AgentKind.self, forKey: .agent)
        model = try c.decode(String.self, forKey: .model)
        reasoning = try c.decodeIfPresent(String.self, forKey: .reasoning)
        requestedLaunch = try c.decodeIfPresent(LaunchRequest.self, forKey: .requestedLaunch)
        modelReason = try c.decode(String.self, forKey: .modelReason)
        brief = try c.decode(String.self, forKey: .brief)
        agentPinned = try c.decode(Bool.self, forKey: .agentPinned)
        launch = try c.decode(LaunchAttempt.self, forKey: .launch)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        conversation = try c.decodeIfPresent(String.self, forKey: .conversation)
        role = try c.decodeIfPresent(TabRole.self, forKey: .role) ?? .work
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(agent, forKey: .agent)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(reasoning, forKey: .reasoning)
        try c.encodeIfPresent(requestedLaunch, forKey: .requestedLaunch)
        try c.encode(modelReason, forKey: .modelReason)
        try c.encode(brief, forKey: .brief)
        try c.encode(agentPinned, forKey: .agentPinned)
        try c.encode(launch, forKey: .launch)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(failure, forKey: .failure)
        try c.encodeIfPresent(conversation, forKey: .conversation)
        // Work is the omitted default role.
        if role != .work { try c.encode(role, forKey: .role) }
    }
}

/// An agent's review of a task's branch (spec §3.1, §5's base): the reviewer, what it was asked, the branch's
/// head it read, and once it answered, its findings, or why it gave none. Nobody is notified, so it needs
/// no slice. Running while neither `findings` nor `failure` is set.
public struct AgentReviewResult: Codable, Equatable, Sendable {
    public var agent: AgentKind
    public var instructions: String
    /// The commit the review read: the branch's head when it started.
    public var head: String?
    public var startedAt: Date
    public var findings: String?
    public var failure: String?
    /// When it answered, or failed.
    public var at: Date?

    public init(agent: AgentKind, instructions: String, head: String?, startedAt: Date, findings: String? = nil,
                failure: String? = nil, at: Date? = nil) {
        self.agent = agent; self.instructions = instructions; self.head = head; self.startedAt = startedAt
        self.findings = findings; self.failure = failure; self.at = at
    }

    public var isRunning: Bool { findings == nil && failure == nil }
}

/// People's review of a task's request (spec §5, the Review slice): who was asked, and what AiTerm last
/// read of the request, so only news wakes the Operator: each thread by its id with whether it was
/// resolved, each thread's last note (its author and a hash of its text), and who approved. `ended` is the
/// Operator's second `finish_task`, which ended the review. `startedAt` is when the task went into review, which the
/// quiet review (spec §K) is measured from; nil for a review recorded before it was kept.
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

/// A flag on top of a task's state (spec §8). Advisory, so one a newer build wrote is dropped on
/// read rather than failing the task (`OperatedTask.init(from:)`).
public enum OperatedFlag: String, Codable, CaseIterable, Sendable { case possiblyStalled, uncertain, upstreamReplaced, waitingOnYou }

/// What Auto-close waits for before it closes a task (`TaskAutoCloser`): the removal is tried again once it is over. Its
/// card says it in the person's short copy while the closing waits.
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

/// What a launch API requested. Nil fields mean omitted; a nil record predates this metadata.
public struct LaunchRequest: Codable, Equatable, Sendable {
    public var model: String?
    public var reasoning: String?
    public init(model: String?, reasoning: String?) { self.model = model; self.reasoning = reasoning }
}

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
    /// the board shows apart from what it adds.
    public var firstRevision: Int
    public var acceptance: TaskAcceptance?, publication: TaskPublication?
    /// While true, the operator's tools refuse the task (spec §8, Take over / Hand back).
    public var takenOver: Bool
    /// The generation a takeover increments: a delivery begun under an older one never finishes.
    public var ownership: Int
    public var launch: LaunchAttempt?
    public var retriesUsed: Int
    /// Working seconds without a new commit on its task branch, excluding idle time and waiting on you.
    public var runtimeUsed: TimeInterval
    /// Working seconds since starting or the Operator last resumed it; commits do not reset this clock.
    public var totalRuntimeUsed: TimeInterval
    /// The task branch's last observed head; a first reading establishes a baseline without resetting runtime.
    public var runtimeHead: String?
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
    public var requestedLaunch: LaunchRequest?
    /// The prompt or the Instructions named the task's agent: it starts on that agent whatever its use.
    public var agentPinned: Bool
    /// The id of the AiTerm issue blocking it, while one does.
    public var problem: String?
    /// Saved review evidence, retained as data. Current reviews run in tabs and record verdicts.
    public var agentReview: AgentReviewResult?
    /// People's review of its request, once the Review slice involved them or it went into review.
    public var peopleReview: PeopleReview?
    /// Its worker committed off its task branch, as AiTerm last found it (`BranchDrift`).
    public var branchDrift: BranchDrift?
    /// The worker tabs the Operator added beside its first worker (`open_tab`), in the order asked for.
    public var extraTabs: [ExtraTab]
    /// The commit it was accepted on when `.reopen` sent it back to its worker (spec §D): accepting again on another
    /// commit replaces what its stacked children built on (`UpstreamReplacement.revokeDependents`); any acceptance clears it.
    public var reopenedFrom: String?
    /// What its review tabs found, each against the commit it reviewed (`record_review`), oldest first.
    public var reviewVerdicts: [ReviewVerdict]
    /// Why the broadcast's closing kept its worktree, row and tabs, in a sentence its card shows; nil while it kept none.
    public var keptReason: String?
    /// What the closing waits for before it tries this task again, which its card says while the closing is due; nil while
    /// it waits for nothing.
    public var closingWait: ClosingWait?
    /// The fork recorded before its worker launched, refined to its current base when accepted: its code
    /// parent's accepted commit, or else where its branch left its base. Auto-close carries it into the task's
    /// `FinishedTaskRecord`, as a merge makes the accepted commit part of the base it would be worked out from.
    public var diffBaseSHA: String?

    public init(runId: UUID, key: String, state: OperatedState = .planned, end: TaskEnd = .commit, brief: String,
                dependsOn: [TaskDependency] = [], stackedOn: UUID? = nil, revision: Int, firstRevision: Int? = nil,
                acceptance: TaskAcceptance? = nil, publication: TaskPublication? = nil, takenOver: Bool = false,
                ownership: Int = 0, launch: LaunchAttempt? = nil, retriesUsed: Int = 0, runtimeUsed: TimeInterval = 0,
                totalRuntimeUsed: TimeInterval? = nil, runtimeHead: String? = nil,
                blockedReason: String? = nil, blockedFrom: OperatedState? = nil, flags: Set<OperatedFlag> = [],
                lastFailure: String? = nil, modelReason: String? = nil, agentPinned: Bool = false, problem: String? = nil,
                agentReview: AgentReviewResult? = nil, peopleReview: PeopleReview? = nil, branchDrift: BranchDrift? = nil,
                extraTabs: [ExtraTab] = [], reopenedFrom: String? = nil, reviewVerdicts: [ReviewVerdict] = []) {
        self.runId = runId; self.key = key; self.state = state; self.end = end; self.brief = brief
        self.dependsOn = dependsOn; self.stackedOn = stackedOn; self.revision = revision
        self.firstRevision = firstRevision ?? revision
        self.acceptance = acceptance; self.publication = publication; self.takenOver = takenOver
        self.ownership = ownership; self.launch = launch; self.retriesUsed = retriesUsed; self.runtimeUsed = runtimeUsed
        self.totalRuntimeUsed = totalRuntimeUsed ?? 0; self.runtimeHead = runtimeHead
        self.blockedReason = blockedReason; self.blockedFrom = blockedFrom; self.flags = flags
        self.lastFailure = lastFailure
        self.modelReason = modelReason; self.agentPinned = agentPinned; self.problem = problem
        self.agentReview = agentReview; self.peopleReview = peopleReview; self.branchDrift = branchDrift
        self.extraTabs = extraTabs; self.reopenedFrom = reopenedFrom; self.reviewVerdicts = reviewVerdicts
    }

    /// Whether a worker was ever launched for it: what makes it "started" for the plan, whatever its
    /// state is now.
    public var started: Bool { launch != nil }

    private enum CodingKeys: String, CodingKey {
        case runId, key, state, end, brief, dependsOn, stackedOn, revision, firstRevision, acceptance, publication
        case takenOver, ownership, launch, retriesUsed, runtimeUsed, totalRuntimeUsed, runtimeHead
        case blockedReason, blockedFrom, lastFailure, flags
        case requestedLaunch
        case modelReason, agentPinned, problem, agentReview, peopleReview, branchDrift, extraTabs, reopenedFrom, reviewVerdicts, keptReason
        case closingWait, diffBaseSHA
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
        totalRuntimeUsed = try c.decodeIfPresent(TimeInterval.self, forKey: .totalRuntimeUsed) ?? 0
        runtimeHead = try c.decodeIfPresent(String.self, forKey: .runtimeHead)
        blockedReason = try c.decodeIfPresent(String.self, forKey: .blockedReason)
        blockedFrom = try c.decodeIfPresent(OperatedState.self, forKey: .blockedFrom)
        lastFailure = try c.decodeIfPresent(String.self, forKey: .lastFailure)
        flags = Set((try c.decodeIfPresent([String].self, forKey: .flags) ?? []).compactMap(OperatedFlag.init(rawValue:)))
        modelReason = try c.decodeIfPresent(String.self, forKey: .modelReason)
        requestedLaunch = try c.decodeIfPresent(LaunchRequest.self, forKey: .requestedLaunch)
        agentPinned = try c.decodeIfPresent(Bool.self, forKey: .agentPinned) ?? false
        problem = try c.decodeIfPresent(String.self, forKey: .problem)
        // Optional review and branch facts belong to this task.
        agentReview = try c.decodeIfPresent(AgentReviewResult.self, forKey: .agentReview)
        peopleReview = try c.decodeIfPresent(PeopleReview.self, forKey: .peopleReview)
        branchDrift = try c.decodeIfPresent(BranchDrift.self, forKey: .branchDrift)
        extraTabs = try c.decodeIfPresent([ExtraTab].self, forKey: .extraTabs) ?? []
        reopenedFrom = try c.decodeIfPresent(String.self, forKey: .reopenedFrom)
        reviewVerdicts = try c.decodeIfPresent([ReviewVerdict].self, forKey: .reviewVerdicts) ?? []
        keptReason = try c.decodeIfPresent(String.self, forKey: .keptReason)
        closingWait = try c.decodeIfPresent(ClosingWait.self, forKey: .closingWait)
        diffBaseSHA = try c.decodeIfPresent(String.self, forKey: .diffBaseSHA)
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
        try c.encode(totalRuntimeUsed, forKey: .totalRuntimeUsed)
        try c.encodeIfPresent(runtimeHead, forKey: .runtimeHead)
        try c.encodeIfPresent(blockedReason, forKey: .blockedReason)
        try c.encodeIfPresent(blockedFrom, forKey: .blockedFrom)
        try c.encodeIfPresent(lastFailure, forKey: .lastFailure)
        // Sorted, so the file does not change on a resave of the same flags.
        try c.encode(flags.map(\.rawValue).sorted(), forKey: .flags)
        try c.encodeIfPresent(modelReason, forKey: .modelReason)
        try c.encodeIfPresent(requestedLaunch, forKey: .requestedLaunch)
        try c.encode(agentPinned, forKey: .agentPinned)
        try c.encodeIfPresent(problem, forKey: .problem)
        try c.encodeIfPresent(agentReview, forKey: .agentReview)
        try c.encodeIfPresent(peopleReview, forKey: .peopleReview)
        try c.encodeIfPresent(branchDrift, forKey: .branchDrift)
        // Empty tab and verdict lists are omitted in the current saved format.
        if !extraTabs.isEmpty { try c.encode(extraTabs, forKey: .extraTabs) }
        try c.encodeIfPresent(reopenedFrom, forKey: .reopenedFrom)
        if !reviewVerdicts.isEmpty { try c.encode(reviewVerdicts, forKey: .reviewVerdicts) }
        try c.encodeIfPresent(keptReason, forKey: .keptReason)
        try c.encodeIfPresent(closingWait, forKey: .closingWait)
        try c.encodeIfPresent(diffBaseSHA, forKey: .diffBaseSHA)
    }
}

/// A question the operator opened with `ask_you`; `id` is its key. Open until `resolution`.
public struct OperatorQuestion: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var task: UUID?
    public var askedAt: Date
    public var resolution: String?
    /// For a prompt open in one of its task's extra worker tabs (`open_tab`), that tab's key; nil for any other question.
    public var tab: String?
    /// For a command the Oracle stopped and asked the person about (`gate-<n>`, spec §A.3), that command where it ran;
    /// nil for any other question.
    public var gate: GateRequest?
    /// For an `ask_you` question about a task, the first line of the newest prompt you typed into that task's worker
    /// instead of answering in the Operator's chat (spec §I). AiTerm writes it while the question is open and never closes
    /// the question: the Operator checks whether it is answered and calls `resolve_question`. Nil for any other question.
    public var answeredInWindow: String?
    /// For a `fixRounds` question, your answer from the task's card, by its case (`oneMoreRound`, `acceptAsItIs`:
    /// `BroadcastBoard.FixRoundsAnswer`). AiTerm writes it once and never closes the question: the Operator resolves
    /// it, as with an answer in its chat. Nil until answered there, and for any other question.
    public var answeredOnCard: String?
    /// True when the Operator withdrew the question; `resolution` is its reason, not the person's answer.
    /// Nil in older runs and for questions that were not withdrawn.
    public var withdrawn: Bool?
    /// What an `ask_you` question is about, when AiTerm acts on it: `fixRounds`, a task out of its review's fix rounds,
    /// whose card offers the answers. Nil for any other question.
    public var about: String?
    public init(id: String, text: String, task: UUID?, askedAt: Date, resolution: String? = nil, tab: String? = nil,
                gate: GateRequest? = nil, answeredInWindow: String? = nil, withdrawn: Bool? = nil, about: String? = nil,
                answeredOnCard: String? = nil) {
        self.id = id; self.text = text; self.task = task; self.askedAt = askedAt; self.resolution = resolution; self.tab = tab
        self.gate = gate; self.answeredInWindow = answeredInWindow; self.withdrawn = withdrawn; self.about = about
        self.answeredOnCard = answeredOnCard
    }

    /// `about` for a task out of its review's fix rounds.
    public static let fixRounds = "fixRounds"

    /// The keys AiTerm records its own questions under: a worker's prompt is `prompt-<task>-<n>`, a merge on the host
    /// `merged-on-host-<task>`, a command the Oracle stopped `gate-<n>`. The Operator picks no key in these namespaces.
    /// AiTerm closes a prompt's question itself; a merge on the host and a stopped command are the person's to decide,
    /// and the Operator closes them once they have answered, a stopped command with whether they allowed it.
    /// The Operator may instead withdraw a stopped command it no longer needs, without allowing it.
    public static let promptPrefix = "prompt-", mergedOnHostPrefix = "merged-on-host-", gatePrefix = "gate-"
    public static let aitermPrefixes = [promptPrefix, mergedOnHostPrefix, gatePrefix]
}

/// A shell command of the Operator's and the directory it runs in, as the gate judges it (spec §A): what a `gate-`
/// question asks about, and what the person's allowance lets pass once.
public struct GateRequest: Codable, Equatable, Sendable {
    public var command: String
    public var directory: String
    public init(command: String, directory: String) { self.command = command; self.directory = directory }
}

/// One line of the decisions log; `why` is its reason in a sentence, `challenge` the Oracle's critique and
/// the reply, and `objection` the Oracle's, when it disagreed and the Operator decided anyway.
public struct OperatorDecision: Codable, Equatable, Sendable {
    public var key: String
    public var text: String
    public var task: UUID?
    public var at: Date
    public var challenge: String?
    public var why: String?
    public var objection: String?
    public init(key: String, text: String, task: UUID?, at: Date, challenge: String? = nil, why: String? = nil,
                objection: String? = nil) {
        self.key = key; self.text = text; self.task = task; self.at = at; self.challenge = challenge
        self.why = why; self.objection = objection
    }

    /// The decision's reason in one line: why, then the Oracle's objection when there is one.
    public var reason: String? {
        let parts = [why.said, objection.said.map { "The Oracle objected: “\($0)”" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Something the Operator found that the brief did not ask for (spec §4.1): never worked on, read by the
/// Operator for its summary, and filed as `ticket` when the Jira slice is on.
public struct OffBriefFind: Codable, Equatable, Sendable {
    public var key: String
    public var title: String
    public var why: String
    public var ticket: String?
    public init(key: String, title: String, why: String, ticket: String? = nil) {
        self.key = key; self.title = title; self.why = why; self.ticket = ticket
    }
}

/// Something AiTerm showed the Operator that was not true, which it checked at the real source and worked
/// around (`report_snag`): kept on the run beside the summary, and worded by `fixTask` as the prompt of an AiTerm
/// task that fixes the bug. `task`, `taskKey` and `branch` are the task it happened on, when it was one.
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

/// Where a challenged tool call stands (spec §4.4): the Oracle running, its critique ready
/// but not yet read, read by the operator, unavailable — the act then proceeds unchallenged — or acted on.
public enum ChallengeStage: String, Codable, CaseIterable, Sendable { case running, ready, delivered, unchallenged, acted }

/// What the Oracle gives a challenged call: a critique the Operator answers or acts on (spec §8), or a
/// veto on a backlog addition past the threshold (spec §4.1), which only a yes lets act.
public enum ChallengeKind: String, Codable, Sendable { case critique, veto }

/// One challenged tool call, kept in its run (spec §4.4, §11): the call it challenged, what the
/// Oracle said, and — once a call with its id acted — that call and its answer. A repeat of
/// the acting call (its reply lost, AiTerm restarted) returns the recorded answer and acts no
/// further. `id` is the `challengeId` the operator calls again with.
public struct ChallengeRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var tool: String
    /// A critique, or a veto; a record saved before vetoes is a critique.
    public var kind: ChallengeKind
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

    public init(id: String, tool: String, kind: ChallengeKind = .critique, stage: ChallengeStage = .running, critique: String? = nil,
                approved: Bool? = nil, askedArguments: String? = nil, askedSHA: String? = nil, unchallengedReason: String? = nil,
                actedArguments: String? = nil, result: String? = nil, askedAt: Date, askedMerge: Bool? = nil, askedEvidence: String? = nil) {
        self.id = id; self.tool = tool; self.kind = kind; self.stage = stage; self.critique = critique; self.approved = approved
        self.askedArguments = askedArguments; self.askedSHA = askedSHA; self.askedMerge = askedMerge
        self.unchallengedReason = unchallengedReason; self.actedArguments = actedArguments; self.result = result
        self.askedAt = askedAt; self.askedEvidence = askedEvidence
    }

    private enum CodingKeys: String, CodingKey {
        case askedEvidence
        case id, tool, kind, stage, critique, approved, askedArguments, askedSHA, askedMerge, unchallengedReason, actedArguments, result, askedAt
    }

    /// Whether a finish_task's yes is a merge's (`askedMerge`).
    public var asksMerge: Bool { askedMerge ?? (askedSHA != nil) }

    /// Synthesised but for `kind`, which a record saved before vetoes lacks: it reads as a critique.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        tool = try c.decode(String.self, forKey: .tool)
        kind = try c.decodeIfPresent(ChallengeKind.self, forKey: .kind) ?? .critique
        stage = try c.decode(ChallengeStage.self, forKey: .stage)
        critique = try c.decodeIfPresent(String.self, forKey: .critique)
        approved = try c.decodeIfPresent(Bool.self, forKey: .approved)
        askedArguments = try c.decodeIfPresent(String.self, forKey: .askedArguments)
        askedSHA = try c.decodeIfPresent(String.self, forKey: .askedSHA)
        askedEvidence = try c.decodeIfPresent(String.self, forKey: .askedEvidence)
        askedMerge = try c.decodeIfPresent(Bool.self, forKey: .askedMerge)
        unchallengedReason = try c.decodeIfPresent(String.self, forKey: .unchallengedReason)
        actedArguments = try c.decodeIfPresent(String.self, forKey: .actedArguments)
        result = try c.decodeIfPresent(String.self, forKey: .result)
        askedAt = try c.decode(Date.self, forKey: .askedAt)
    }
}

/// A broadcast, "run" in code (spec §4, §5). The app is its only writer.
public struct OperatorRun: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Settings › Operator as it was when the broadcast started: a change there applies to the next one.
    public var profile: OperatorProfile
    /// The run's scope: every task belongs to one of these projects.
    public var projectIds: [UUID]
    /// The Jira projects its tickets are in, by key.
    public var jiraProjectKeys: [String]
    /// What you asked for, how its work is reviewed, and what done looks like.
    public var prompt: String
    public var state: OperatorRunState
    /// `.paused` or `.stopped` when you said so; persisted, and never undone by reconciliation.
    public var intent: OperatorRunState?
    /// The last submitted plan revision, 0 while none is. New and changed tasks go into the open
    /// one, `openRevision`; `submit_plan` closes it and releases its tasks (`PlanRevision`).
    public var planRevision: Int
    /// How many tasks the first submitted plan had: what the backlog's growth is measured against.
    public var firstPlanSize: Int?
    public var questions: [OperatorQuestion], decisions: [OperatorDecision]
    /// The off-brief finds, for the Operator's summary; and what the slices kept the Operator from doing.
    public var finds: [OffBriefFind], leftForYou: [String]
    /// What AiTerm got wrong that the Operator worked around, kept beside the summary (`report_snag`).
    public var snags: [OperatorSnag]
    /// What each `leave_for_you` call recorded, by the key the Operator gave it: the same key again records nothing.
    /// Left out of the save while empty.
    public var leftForYouRecords: [String: String] = [:]
    /// The tickets `jira_create` made, by the key the Operator gave the call: the same key again returns the ticket.
    public var jiraCreated: [String: String]
    /// Where each `jira_sprint` call put its tickets, by the key the Operator gave it (a sprint's id, or `backlog`): the same
    /// key again moves nothing. Left out of the save while empty.
    public var jiraSprinted: [String: String] = [:]
    /// The id of the comment each `jira_comment` call posted, by the key the Operator gave it: the same key again posts
    /// nothing. Left out of the save while empty.
    public var jiraCommented: [String: String] = [:]
    /// The review threads `reply_thread` answered, by the key the Operator gave the call: the same key again posts nothing.
    public var threadReplies: [String: String]
    /// The writes sent and not yet known to have landed, as `jira_create/<key>` and `reply_thread/<key>`: saved before
    /// the request goes, cleared once its answer is recorded or it is known to have failed. A retry of one still here
    /// may find the first one done.
    public var pendingWrites: [String]
    /// The Oracle's challenges of this run's calls, the ones acted on kept with their answer.
    public var challenges: [ChallengeRecord]
    /// The Operator's Claude conversation, for `claude --resume`.
    public var operatorConversation: String?, operatorWindowId: String?, operatorSessionId: String?
    public var createdAt: Date
    /// The Operator's prose summary of the broadcast (`write_summary`) and when it came; `RunSummary` reads them.
    public var summary: String?, summaryAt: Date?
    /// When the plan was done: every task finished, and the run `.complete`. Cleared when a new plan reopens it.
    public var completedAt: Date?
    /// AiTerm stopped waiting for a summary (`OperatorTiming.summaryWait`): it is not coming.
    public var summaryGivenUp = false
    /// When the broadcast ended, for the Shelf.
    public var endedAt: Date?
    /// The commands the person allowed after the Oracle stopped them (`resolve_question` with `allow`): each passes the
    /// gate once, on the exact command and directory, and is used up (spec §A.3).
    public var gateAllowances: [GateRequest] = []
    /// The only combinations its workers, tabs and reviewers start on.
    public var agents: [AgentChoice]
    /// The task policy, frozen as the broadcast starts.
    public var taskSettings: TaskSettings
    /// The Done step's goal; nil for none.
    public var goal: BroadcastGoal?
    /// Every task is finished and the goal is still to check: the run stays `.active` until `check_goal` answers.
    public var goalCheckDue = false
    /// The extra rounds a goal check has used.
    public var roundsUsed = 0
    /// Each `check_goal` that acted, oldest first.
    public var goalChecks: [GoalCheck] = []
    public var goalOutcome: GoalOutcome?
    /// The plan revision when the last goal check was answered: a later submitted one makes another check due.
    public var revisionAtLastCheck: Int?
    /// The tasks closed and removed at the broadcast's end, as their cards read.
    public var finished: [FinishedTaskRecord] = []
    /// When the closing last ran.
    public var closedAt: Date?

    /// `projectIds` defaults to none: a run made in a test or a fixture that never reads its scope.
    public init(id: UUID, name: String, profile: OperatorProfile, projectIds: [UUID] = [], jiraProjectKeys: [String] = [],
                prompt: String, state: OperatorRunState = .planning,
                intent: OperatorRunState? = nil, planRevision: Int = 0, firstPlanSize: Int? = nil,
                questions: [OperatorQuestion] = [], decisions: [OperatorDecision] = [], finds: [OffBriefFind] = [],
                snags: [OperatorSnag] = [], leftForYou: [String] = [], operatorConversation: String? = nil, operatorWindowId: String? = nil,
                operatorSessionId: String? = nil, challenges: [ChallengeRecord] = [], jiraCreated: [String: String] = [:],
                threadReplies: [String: String] = [:], pendingWrites: [String] = [], createdAt: Date,
                summary: String? = nil, summaryAt: Date? = nil, completedAt: Date? = nil, summaryGivenUp: Bool = false,
                endedAt: Date? = nil, agents: [AgentChoice] = [], taskSettings: TaskSettings = TaskSettings(review: nil, end: .draftMR), goal: BroadcastGoal? = nil) {
        self.id = id; self.name = name; self.profile = profile; self.projectIds = projectIds; self.jiraProjectKeys = jiraProjectKeys
        self.prompt = prompt; self.state = state; self.intent = intent
        self.planRevision = planRevision; self.firstPlanSize = firstPlanSize
        self.questions = questions; self.decisions = decisions; self.finds = finds; self.snags = snags; self.leftForYou = leftForYou
        self.operatorConversation = operatorConversation; self.operatorWindowId = operatorWindowId
        self.operatorSessionId = operatorSessionId; self.challenges = challenges; self.jiraCreated = jiraCreated
        self.threadReplies = threadReplies; self.pendingWrites = pendingWrites
        self.createdAt = createdAt
        self.summary = summary; self.summaryAt = summaryAt; self.completedAt = completedAt
        self.summaryGivenUp = summaryGivenUp; self.endedAt = endedAt
        self.agents = agents; self.taskSettings = taskSettings; self.goal = goal
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, profile, projectIds, jiraProjectKeys, prompt, state, intent, planRevision
        case firstPlanSize, questions, decisions, finds, snags, leftForYou, leftForYouRecords, challenges, operatorConversation, operatorWindowId
        case operatorSessionId, jiraCreated, jiraSprinted, jiraCommented, threadReplies, pendingWrites, createdAt
        case summary, summaryAt, completedAt, summaryGivenUp, endedAt, gateAllowances
        case agents, taskSettings, goal, goalCheckDue, roundsUsed, goalChecks, goalOutcome, revisionAtLastCheck, finished, closedAt
    }

    /// The lists may be missing and read as empty. A run without a profile or a prompt (round 1's,
    /// with its persona) fails, and `AppState` keeps it whole without showing it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        profile = try c.decode(OperatorProfile.self, forKey: .profile)
        projectIds = try c.decodeIfPresent([UUID].self, forKey: .projectIds) ?? []
        jiraProjectKeys = try c.decodeIfPresent([String].self, forKey: .jiraProjectKeys) ?? []
        prompt = try c.decode(String.self, forKey: .prompt)
        state = try c.decode(OperatorRunState.self, forKey: .state)
        intent = try c.decodeIfPresent(OperatorRunState.self, forKey: .intent)
        planRevision = try c.decode(Int.self, forKey: .planRevision)
        firstPlanSize = try c.decodeIfPresent(Int.self, forKey: .firstPlanSize)
        questions = try c.decodeIfPresent([OperatorQuestion].self, forKey: .questions) ?? []
        decisions = try c.decodeIfPresent([OperatorDecision].self, forKey: .decisions) ?? []
        finds = try c.decodeIfPresent([OffBriefFind].self, forKey: .finds) ?? []
        snags = try c.decodeIfPresent([OperatorSnag].self, forKey: .snags) ?? []
        leftForYou = try c.decodeIfPresent([String].self, forKey: .leftForYou) ?? []
        leftForYouRecords = try c.decodeIfPresent([String: String].self, forKey: .leftForYouRecords) ?? [:]
        challenges = try c.decodeIfPresent([ChallengeRecord].self, forKey: .challenges) ?? []
        operatorConversation = try c.decodeIfPresent(String.self, forKey: .operatorConversation)
        operatorWindowId = try c.decodeIfPresent(String.self, forKey: .operatorWindowId)
        operatorSessionId = try c.decodeIfPresent(String.self, forKey: .operatorSessionId)
        jiraCreated = try c.decodeIfPresent([String: String].self, forKey: .jiraCreated) ?? [:]
        jiraSprinted = try c.decodeIfPresent([String: String].self, forKey: .jiraSprinted) ?? [:]
        jiraCommented = try c.decodeIfPresent([String: String].self, forKey: .jiraCommented) ?? [:]
        threadReplies = try c.decodeIfPresent([String: String].self, forKey: .threadReplies) ?? [:]
        pendingWrites = try c.decodeIfPresent([String].self, forKey: .pendingWrites) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        summaryAt = try c.decodeIfPresent(Date.self, forKey: .summaryAt)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        summaryGivenUp = try c.decodeIfPresent(Bool.self, forKey: .summaryGivenUp) ?? false
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        gateAllowances = try c.decodeIfPresent([GateRequest].self, forKey: .gateAllowances) ?? []
        agents = try c.decodeIfPresent([AgentChoice].self, forKey: .agents) ?? []
        taskSettings = try c.decode(TaskSettings.self, forKey: .taskSettings)
        goal = try c.decodeIfPresent(BroadcastGoal.self, forKey: .goal)
        goalCheckDue = try c.decodeIfPresent(Bool.self, forKey: .goalCheckDue) ?? false
        roundsUsed = try c.decodeIfPresent(Int.self, forKey: .roundsUsed) ?? 0
        goalChecks = try c.decodeIfPresent([GoalCheck].self, forKey: .goalChecks) ?? []
        goalOutcome = try c.decodeIfPresent(GoalOutcome.self, forKey: .goalOutcome)
        revisionAtLastCheck = try c.decodeIfPresent(Int.self, forKey: .revisionAtLastCheck)
        finished = try c.decodeIfPresent([FinishedTaskRecord].self, forKey: .finished) ?? []
        closedAt = try c.decodeIfPresent(Date.self, forKey: .closedAt)
    }

    /// A new plan on a finished run: the summary, its time, the completion and the give-up belonged to the old
    /// one. The end time stays, since only an ended run has one.
    public mutating func reopen() {
        summary = nil; summaryAt = nil; completedAt = nil; summaryGivenUp = false
    }

    /// The revision `create_task` and `update_task` add to: the one after the last submitted.
    public var openRevision: Int { planRevision + 1 }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(profile, forKey: .profile)
        try c.encode(projectIds, forKey: .projectIds)
        try c.encode(jiraProjectKeys, forKey: .jiraProjectKeys)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(intent, forKey: .intent)
        try c.encode(planRevision, forKey: .planRevision)
        try c.encodeIfPresent(firstPlanSize, forKey: .firstPlanSize)
        try c.encode(questions, forKey: .questions)
        try c.encode(decisions, forKey: .decisions)
        try c.encode(finds, forKey: .finds)
        try c.encode(snags, forKey: .snags)
        try c.encode(leftForYou, forKey: .leftForYou)
        if !leftForYouRecords.isEmpty { try c.encode(leftForYouRecords, forKey: .leftForYouRecords) }
        try c.encode(challenges, forKey: .challenges)
        try c.encodeIfPresent(operatorConversation, forKey: .operatorConversation)
        try c.encodeIfPresent(operatorWindowId, forKey: .operatorWindowId)
        try c.encodeIfPresent(operatorSessionId, forKey: .operatorSessionId)
        try c.encode(jiraCreated, forKey: .jiraCreated)
        if !jiraSprinted.isEmpty { try c.encode(jiraSprinted, forKey: .jiraSprinted) }
        if !jiraCommented.isEmpty { try c.encode(jiraCommented, forKey: .jiraCommented) }
        try c.encode(threadReplies, forKey: .threadReplies)
        try c.encode(pendingWrites, forKey: .pendingWrites)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(summaryAt, forKey: .summaryAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        if summaryGivenUp { try c.encode(true, forKey: .summaryGivenUp) }
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        // Left out while there are none, so a run without one saves as it did before.
        if !gateAllowances.isEmpty { try c.encode(gateAllowances, forKey: .gateAllowances) }
        // Each left out while empty or nil, as a run started before them saved.
        if !agents.isEmpty { try c.encode(agents, forKey: .agents) }
        try c.encode(taskSettings, forKey: .taskSettings)
        try c.encodeIfPresent(goal, forKey: .goal)
        if goalCheckDue { try c.encode(true, forKey: .goalCheckDue) }
        if roundsUsed != 0 { try c.encode(roundsUsed, forKey: .roundsUsed) }
        if !goalChecks.isEmpty { try c.encode(goalChecks, forKey: .goalChecks) }
        try c.encodeIfPresent(goalOutcome, forKey: .goalOutcome)
        try c.encodeIfPresent(revisionAtLastCheck, forKey: .revisionAtLastCheck)
        if !finished.isEmpty { try c.encode(finished, forKey: .finished) }
        try c.encodeIfPresent(closedAt, forKey: .closedAt)
    }
}

public extension OperatedTask {
    /// The ends a task reaches by being done: no change needed, published, stopped, or accepted with
    /// nothing left to publish (a commit end, or a publication left for you).
    var isFinished: Bool {
        state == .noChange || state == .published || state == .stopped
            || (state == .accepted && (end == .commit || publication?.leftForYou == true))
    }
}
