import Foundation

/// Who asks for a transition (spec §8's "Who" column). The operator only ever acts through its
/// tools, so `.operatorTool` is every MCP call; `.you` is a click in AiTerm; `.aiterm` is the app
/// on its own — the scheduler, a submitted ungated plan, a limit used up.
public enum OperatedActor: String, Sendable { case operatorTool, you, aiterm }

/// One row of spec §8's table, asked for.
public enum OperatedAction: Equatable, Sendable {
    /// You, **Approve plan** on a gated run: `planned` → `queued`, for tasks of `revision` or older.
    case approve(revision: Int)
    /// AiTerm, on `submit_plan` in an ungated run: `planned` → `queued`, the same way.
    case release(revision: Int)
    /// AiTerm, when `RunScheduler` says it may: `queued` → `working`. The attempt is the launch
    /// intent, saved before the worker's window is asked for (spec §11).
    case start(LaunchAttempt)
    /// The operator's `mark_task(accepted)`. `branchHead` is the task branch's head now, read by
    /// the caller: the engine is pure, and the accepted SHA must be that head, unmoved.
    case accept(TaskAcceptance, branchHead: String)
    case noChange(note: String?)
    /// The operator's `mark_task(blocked)`, or AiTerm when retries or runtime are used up.
    case block(reason: String)
    case fail(reason: String)
    /// The operator's `resume_task`, once the reason is resolved.
    case resume
    /// The operator's `retry_task`, while retries are left.
    case retry
    /// `finish_task` (M3) has carried out the task's end; `publication` records its steps.
    case publish(TaskPublication)
    /// You: Stop task, or Stop on the whole operation.
    case stop
}

/// What a transition depends on beyond the task itself, gathered by the caller from the run.
public struct OperatedContext: Equatable, Sendable {
    public var runState: OperatorRunState
    /// The run's snapshot `limits.retries`.
    public var retryLimit: Int
    /// Whether a task with a `code` dependency on this one has started (M1 re-accept rule, spec §8).
    public var codeDependentStarted: Bool
    public var milestone: OperatorMilestone
    /// The run's snapshot `limits.runtimeMinutes`, in seconds; nil where a caller does not say.
    public var runtimeLimit: TimeInterval?

    public init(runState: OperatorRunState, retryLimit: Int, codeDependentStarted: Bool = false,
                milestone: OperatorMilestone = .current, runtimeLimit: TimeInterval? = nil) {
        self.runState = runState; self.retryLimit = retryLimit
        self.codeDependentStarted = codeDependentStarted; self.milestone = milestone
        self.runtimeLimit = runtimeLimit
    }
}

/// Why a transition was refused. The description is what the operator's tool call answers.
public enum OperatedTransitionError: Error, Equatable, CustomStringConvertible {
    case notAllowed(action: String, from: OperatedState)
    case wrongActor(action: String, actor: OperatedActor)
    case takenOver
    case runIs(OperatorRunState)
    case notInRevision(approved: Int, taskRevision: Int)
    case missingEvidence
    case notTheBranchHead(sha: String, head: String)
    case reacceptAfterDependentStarted
    case noRetriesLeft(limit: Int)
    case endIsCommit
    case notInThisMilestone(TaskEnd)
    case publishedSHANotAccepted(String)
    case unknownTask(UUID)
    case notOperated(UUID)
    case unknownRun(UUID)

    public var description: String {
        switch self {
        case .notAllowed(let action, let from): return "A task that is \(from.rawValue) can't \(action)."
        case .wrongActor(let action, let actor): return "\(action) isn't for \(actor.rawValue)."
        case .takenOver: return "You took this task over; it's refused until you hand it back."
        case .runIs(let state): return "The operation is \(state.rawValue)."
        case .notInRevision(let approved, let revision):
            return "The task changed in plan revision \(revision); revision \(approved) doesn't release it."
        case .missingEvidence: return "Accepting needs the result SHA and the worker's check output."
        case .notTheBranchHead(let sha, let head): return "\(sha) isn't the branch's head (\(head)); the branch moved."
        case .reacceptAfterDependentStarted:
            return "A task building on this one has started, so it can't be accepted again on another SHA."
        case .noRetriesLeft(let limit): return "No retries left: all \(limit) are used."
        case .endIsCommit: return "The plan ends this task at a commit; there's nothing to publish."
        case .notInThisMilestone(let end): return "This version of AiTerm can't carry out a \(end.displayName) yet."
        case .publishedSHANotAccepted(let sha): return "\(sha) isn't the accepted SHA."
        case .unknownTask(let id): return "There's no task \(id.uuidString)."
        case .notOperated(let id): return "Task \(id.uuidString) isn't in an operation."
        case .unknownRun(let id): return "There's no operation \(id.uuidString)."
        }
    }
}

/// Spec §8's workflow table as pure functions: what may happen to an operated task, by whom, in
/// which run state, and what else follows. Nothing here reads git, the daemon or the clock — the
/// caller passes the branch head, the launch attempt and the dates — so every row is a unit test.
///
/// Every action is safe to repeat (spec §11): one that finds the task already where it would
/// take it returns it unchanged, so a mutation whose reply was lost answers the same the second time.
public enum OperatedTransitions {
    public static func apply(_ action: OperatedAction, to task: OperatedTask, by actor: OperatedActor,
                             context: OperatedContext) throws(OperatedTransitionError) -> OperatedTask {
        let name = Self.name(action)
        guard allowedActors(action).contains(actor) else { throw .wrongActor(action: name, actor: actor) }
        if task.takenOver, actor != .you { throw .takenOver }
        try checkRun(action, actor: actor, context.runState)

        var next = task
        func refuse() -> OperatedTransitionError { .notAllowed(action: name, from: task.state) }
        switch action {
        case .approve(let revision), .release(let revision):
            if task.state == .queued { return task }
            guard task.state == .planned else { throw refuse() }
            guard task.revision <= revision else { throw .notInRevision(approved: revision, taskRevision: task.revision) }
            next.state = .queued

        case .start(let attempt):
            if task.state == .working, task.launch == attempt { return task }
            guard task.state == .queued else { throw refuse() }
            next.state = .working
            next.launch = attempt
            next.blockedReason = nil

        case .accept(let acceptance, let head):
            // From M3 a published task is accepted again on a new commit (spec §8, upstream
            // replacement): `finish_task` then pushes it to the same request. Before M3 nothing is published.
            let accepted: Set<OperatedState> = context.milestone >= .m3 ? [.accepted, .published] : [.accepted]
            guard task.state == .working || accepted.contains(task.state) else { throw refuse() }
            let sha = acceptance.resultSHA.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sha.isEmpty, !acceptance.checkOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw .missingEvidence }
            // A repeat names the commit already accepted: the earlier result, even if the branch moved since.
            if accepted.contains(task.state), let earlier = task.acceptance, sameCommit(sha, earlier.resultSHA) { return task }
            guard sameCommit(sha, head) else { throw .notTheBranchHead(sha: sha, head: head) }
            if accepted.contains(task.state), task.acceptance != nil {
                // M1 and M2 (spec §8); from M3 the started dependents are replaced instead (part G's `UpstreamReplacement`).
                if context.codeDependentStarted, context.milestone < .m3 { throw .reacceptAfterDependentStarted }
            }
            next.state = .accepted
            // The head, in full: what a dependent branches from and a publication must push.
            next.acceptance = TaskAcceptance(resultSHA: head, prerequisiteSHAs: acceptance.prerequisiteSHAs,
                                             checkOutput: acceptance.checkOutput, note: acceptance.note, at: acceptance.at)
            settle(&next)

        case .noChange:
            if task.state == .noChange { return task }
            guard task.state == .working else { throw refuse() }
            next.state = .noChange
            settle(&next)

        case .block(let reason):
            if task.state == .blocked, task.blockedReason == reason { return task }
            let from: [OperatedState] = actor == .aiterm ? [.working, .failed, .queued, .blocked] : [.working, .blocked]
            guard from.contains(task.state) else { throw refuse() }
            // Remember where it was blocked from, so resume returns it there (a blocked block keeps the first).
            if task.state != .blocked { next.blockedFrom = [.queued, .working].contains(task.state) ? task.state : nil }
            next.state = .blocked
            next.blockedReason = reason

        case .fail(let reason):
            if task.state == .failed { return task }
            guard task.state == .working else { throw refuse() }
            next.state = .failed
            next.blockedReason = reason
            next.lastFailure = reason
            next.flags.subtract([.possiblyStalled, .waitingOnYou])

        case .resume:
            if task.state == .working || (task.state == .queued && task.blockedReason == nil) { return task }
            guard task.state == .blocked else { throw refuse() }
            // Back to where it was blocked from: a queued task waits its turn again, a working one
            // continues in its session. Older files have no record: a task that never ran has no session.
            next.state = task.blockedFrom ?? (task.started ? .working : .queued)
            // A task blocked for its runtime is resumed with a fresh allowance: with the time it used left
            // over, the next pass would block it again. A block for any other reason keeps what was used.
            if next.state == .working, let limit = context.runtimeLimit, task.runtimeUsed >= limit { next.runtimeUsed = 0 }
            next.blockedReason = nil
            next.blockedFrom = nil

        case .retry:
            if task.state == .queued, task.retriesUsed > 0 { return task }
            guard task.state == .failed else { throw refuse() }
            guard task.retriesUsed < context.retryLimit else { throw .noRetriesLeft(limit: context.retryLimit) }
            next.state = .queued
            next.retriesUsed += 1
            next.blockedReason = nil

        case .publish(let publication):
            if task.state == .published, task.publication == publication { return task }
            guard task.state == .accepted || task.state == .published else { throw refuse() }
            guard task.end != .commit else { throw .endIsCommit }
            guard context.milestone.supports(task.end) else { throw .notInThisMilestone(task.end) }
            if let pushed = publication.pushedSHA, let accepted = task.acceptance?.resultSHA, !sameCommit(pushed, accepted) {
                throw .publishedSHANotAccepted(pushed)
            }
            next.state = .published
            next.publication = publication

        case .stop:
            if task.state == .stopped { return task }
            guard task.state.isOpen else { throw refuse() }
            next.state = .stopped
            next.blockedFrom = nil
            next.flags.subtract([.possiblyStalled, .waitingOnYou])
        }
        return next
    }

    /// A task over its limits, and why — what AiTerm blocks it with (spec §8): a failure with no
    /// retry left, or a working task past its runtime. Nil while it is within both.
    public static func limitReason(for task: OperatedTask, limits: OperatorLimits) -> String? {
        if task.state == .failed, task.retriesUsed >= limits.retries {
            return "Failed with no retries left (\(limits.retries) allowed)."
        }
        if task.state == .working, task.runtimeUsed >= TimeInterval(limits.runtimeMinutes * 60) {
            return "Worked its \(limits.runtimeMinutes) minutes without finishing."
        }
        return nil
    }

    /// Two spellings of one commit: equal, or one a prefix of the other at least 7 long, as git
    /// abbreviates. The operator may quote a short SHA; the branch head is read in full.
    public static func sameCommit(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        if a == b { return !a.isEmpty }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        return short.count >= 7 && long.hasPrefix(short)
    }

    // MARK: - Rules

    private static func allowedActors(_ action: OperatedAction) -> Set<OperatedActor> {
        switch action {
        case .approve, .stop: return [.you]
        case .release, .start: return [.aiterm]
        case .block: return [.operatorTool, .aiterm]
        case .accept, .noChange, .fail, .resume, .retry, .publish: return [.operatorTool]
        }
    }

    /// Spec §9: the operator's mutations need an active run — or a complete one, which it may still
    /// talk to and accept in — and new tasks start only in an active run. Your own clicks are not
    /// refused here; a stopped run releases nothing.
    private static func checkRun(_ action: OperatedAction, actor: OperatedActor, _ state: OperatorRunState) throws(OperatedTransitionError) {
        switch action {
        case .start:
            guard state == .active else { throw .runIs(state) }
        case .approve, .release:
            guard state != .stopped else { throw .runIs(state) }
        case .stop:
            return
        default:
            if actor == .operatorTool, state != .active, state != .complete { throw .runIs(state) }
        }
    }

    /// A task that reached an end no longer waits on you or looks stalled.
    private static func settle(_ task: inout OperatedTask) {
        task.blockedReason = nil
        task.lastFailure = nil
        task.flags.subtract([.possiblyStalled, .waitingOnYou])
    }

    static func name(_ action: OperatedAction) -> String {
        switch action {
        case .approve: return "be approved"
        case .release: return "be released"
        case .start: return "start"
        case .accept: return "be accepted"
        case .noChange: return "end with no change"
        case .block: return "be blocked"
        case .fail: return "fail"
        case .resume: return "resume"
        case .retry: return "be retried"
        case .publish: return "be published"
        case .stop: return "be stopped"
        }
    }
}
