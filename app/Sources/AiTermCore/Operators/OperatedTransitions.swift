import Foundation

/// Who asks for a transition (spec §8's "Who" column). The operator only ever acts through its
/// tools, so `.operatorTool` is every MCP call; `.you` is a click in AiTerm; `.aiterm` is the app
/// on its own — the scheduler, a submitted plan, a limit used up.
public enum OperatedActor: String, Sendable { case operatorTool, you, aiterm }

/// One row of spec §8's table, asked for.
public enum OperatedAction: Equatable, Sendable {
    /// AiTerm, on `submit_plan`: `planned` → `queued`, for tasks of `revision` or older.
    case release(revision: Int)
    /// AiTerm, when `RunScheduler` says it may: `queued` → `working`. The attempt is the launch
    /// intent, saved before the worker's window is asked for (spec §11); both runtime clocks start afresh.
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
    /// The operator's `message_task` to an accepted task whose commit is not on origin yet (spec §D): back to `working`,
    /// the worker kept, `reopenedFrom` the commit it was accepted on.
    case reopen
    /// You: Stop task, or Stop on the whole broadcast.
    case stop
}

/// What a transition depends on beyond the task itself, gathered by the caller from the run.
public struct OperatedContext: Equatable, Sendable {
    public var runState: OperatorRunState
    /// The run's snapshot `limits.retries`.
    public var retryLimit: Int

    public init(runState: OperatorRunState, retryLimit: Int) {
        self.runState = runState; self.retryLimit = retryLimit
    }
}

/// Why a transition was refused. The description is what the operator's tool call answers.
public enum OperatedTransitionError: Error, Equatable, CustomStringConvertible {
    case notAllowed(action: String, from: OperatedState)
    case wrongActor(action: String, actor: OperatedActor)
    case takenOver
    case runIs(OperatorRunState)
    case notInRevision(released: Int, taskRevision: Int)
    case missingEvidence
    case notTheBranchHead(sha: String, head: String)
    case noRetriesLeft(limit: Int)
    /// noChange on a task steered back to work after it was accepted on that commit: it would drop the commit.
    case reopenedFromAcceptedCommit(String)
    case unknownTask(UUID)
    case notOperated(UUID)
    case unknownRun(UUID)

    public var description: String {
        switch self {
        case .notAllowed(let action, let from): return "A task that is \(from.rawValue) can't \(action)."
        case .wrongActor(let action, let actor): return "\(action) isn't for \(actor.rawValue)."
        case .takenOver: return "You took this task over; it's refused until you hand it back."
        case .runIs(let state): return "The broadcast is \(state.rawValue)."
        case .notInRevision(let released, let revision):
            return "The task changed in plan revision \(revision); revision \(released) doesn't release it."
        case .missingEvidence: return "Accepting needs the result SHA and the worker's check output."
        case .notTheBranchHead(let sha, let head): return "\(sha) isn't the branch's head (\(head)); the branch moved."
        case .noRetriesLeft(let limit): return "No retries left: all \(limit) are used."
        case .reopenedFromAcceptedCommit(let sha):
            return "This task was accepted on \(sha.prefix(7)) before it was steered back to work, so noChange would drop that commit. "
                + "If its worker needs to change nothing, accept \(sha.prefix(7)) again with mark_task accepted."
        case .unknownTask(let id): return "There's no task \(id.uuidString)."
        case .notOperated(let id): return "Task \(id.uuidString) isn't in a broadcast."
        case .unknownRun(let id): return "There's no broadcast \(id.uuidString)."
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
        case .release(let revision):
            if task.state == .queued { return task }
            guard task.state == .planned else { throw refuse() }
            guard task.revision <= revision else { throw .notInRevision(released: revision, taskRevision: task.revision) }
            next.state = .queued

        case .start(let attempt):
            if task.state == .working, task.launch == attempt { return task }
            guard task.state == .queued else { throw refuse() }
            next.state = .working
            next.launch = attempt
            next.runtimeUsed = 0
            next.totalRuntimeUsed = 0
            next.blockedReason = nil

        case .accept(let acceptance, let head):
            // A published task is accepted again on a new commit (spec §8, upstream replacement): `finish_task`
            // then pushes it to the same request, and the caller replaces what its dependents built on (`UpstreamReplacement`).
            // A task in review is accepted again once its agent fixed the feedback (spec §5, the Review slice).
            let accepted: Set<OperatedState> = [.accepted, .published, .inReview]
            guard task.state == .working || accepted.contains(task.state) else { throw refuse() }
            let sha = acceptance.resultSHA.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sha.isEmpty, !acceptance.checkOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw .missingEvidence }
            // A repeat names the commit already accepted: the earlier result, even if the branch moved since.
            if accepted.contains(task.state), let earlier = task.acceptance, sameCommit(sha, earlier.resultSHA) { return task }
            guard sameCommit(sha, head) else { throw .notTheBranchHead(sha: sha, head: head) }
            next.state = .accepted
            next.reopenedFrom = nil
            // The head, in full: what a dependent branches from and a publication must push.
            next.acceptance = TaskAcceptance(resultSHA: head, prerequisiteSHAs: acceptance.prerequisiteSHAs,
                                             checkOutput: acceptance.checkOutput, note: acceptance.note, at: acceptance.at)
            next.acceptanceWorktreeFingerprint = nil
            settle(&next)

        case .noChange:
            if task.state == .noChange { return task }
            guard task.state == .working else { throw refuse() }
            // Reopened (spec §C, §D): its accepted commit stands until it is accepted again or replaced, never dropped.
            if let earlier = task.reopenedFrom, !earlier.isEmpty { throw .reopenedFromAcceptedCommit(earlier) }
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
            // The Operator has checked the block and put it back to work: both allowances start afresh.
            next.runtimeUsed = 0
            next.totalRuntimeUsed = 0
            next.blockedReason = nil
            next.blockedFrom = nil

        case .retry:
            if task.state == .queued, task.retriesUsed > 0 { return task }
            guard task.state == .failed else { throw refuse() }
            guard task.retriesUsed < context.retryLimit else { throw .noRetriesLeft(limit: context.retryLimit) }
            next.state = .queued
            next.retriesUsed += 1
            next.blockedReason = nil

        case .reopen:
            if task.state == .working, task.reopenedFrom != nil { return task }
            guard isReopenable(task) else { throw refuse() }
            next.state = .working
            next.reopenedFrom = task.acceptance?.resultSHA
            next.acceptance = nil
            next.acceptanceWorktreeFingerprint = nil

        case .stop:
            if task.state == .stopped { return task }
            guard task.state.isOpen || (task.state == .accepted && !task.isFinished) else { throw refuse() }
            next.state = .stopped
            next.blockedFrom = nil
            next.flags.subtract([.possiblyStalled, .waitingOnYou])
        }
        return next
    }

    /// A task over its limits, and why — what AiTerm blocks it with (spec §8): a failure with no
    /// retry left, or a working task past its runtime. Nil while it is within all three, and never for its
    /// runtime while it is `readyForAcceptance`: its worker finished, and the work waits for review.
    /// A pending branch read may leave out only the no-commit rule with `checkNoCommit`.
    public static func limitReason(for task: OperatedTask, readyForAcceptance: Bool = false, retries: Int = OperatorTiming.retries,
                                   checkNoCommit: Bool = true, runtimeMinutes: Int = OperatorTiming.runtimeMinutes,
                                   totalRuntimeHours: Int = OperatorTiming.totalRuntimeHours) -> String? {
        if task.state == .failed, task.retriesUsed >= retries {
            return "Failed with no retries left (\(retries) allowed)."
        }
        if task.state == .working, !readyForAcceptance {
            if task.totalRuntimeUsed >= TimeInterval(totalRuntimeHours * 60 * 60) {
                return "Worked \(totalRuntimeHours) hours since it started or the Operator last resumed it."
            }
            if checkNoCommit, task.runtimeUsed >= TimeInterval(runtimeMinutes * 60) {
                return "Worked \(runtimeMinutes) minutes without a new commit."
            }
        }
        return nil
    }

    /// Whether `task` may go back to its worker (spec §D): accepted, and its accepted commit not on origin yet — nothing
    /// pushed for it, none merged, its publication not left to you. A commit-end task never pushes, so it stays open to
    /// steering until something else ends it.
    public static func isReopenable(_ task: OperatedTask) -> Bool {
        guard task.state == .accepted else { return false }
        let publication = task.publication
        if publication?.merged == true || publication?.mergedSHA != nil || publication?.leftForYou == true { return false }
        guard let pushed = publication?.pushedSHA, let accepted = task.acceptance?.resultSHA else { return true }
        return !sameCommit(pushed, accepted)
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
        case .stop: return [.you]
        case .release, .start: return [.aiterm]
        case .block: return [.operatorTool, .aiterm]
        case .accept, .noChange, .fail, .resume, .retry, .reopen: return [.operatorTool]
        }
    }

    /// Spec §9: the operator's mutations need an active run — or a complete one, which it may still
    /// talk to and accept in — and new tasks start only in an active run. Your own clicks are not
    /// refused here; a stopped run releases nothing.
    private static func checkRun(_ action: OperatedAction, actor: OperatedActor, _ state: OperatorRunState) throws(OperatedTransitionError) {
        switch action {
        case .start:
            guard state == .active else { throw .runIs(state) }
        case .release:
            guard state != .stopped else { throw .runIs(state) }
        case .stop:
            return
        default:
            if actor == .operatorTool, state != .active, state != .complete { throw .runIs(state) }
        }
    }

    /// A task that reached an end no longer waits on you, looks stalled or reads as off its branch: the
    /// Operator checked its result.
    static func settle(_ task: inout OperatedTask) {
        task.blockedReason = nil
        task.lastFailure = nil
        task.branchDrift = nil
        task.flags.subtract([.possiblyStalled, .waitingOnYou])
    }

    static func name(_ action: OperatedAction) -> String {
        switch action {
        case .release: return "be released"
        case .start: return "start"
        case .accept: return "be accepted"
        case .noChange: return "end with no change"
        case .block: return "be blocked"
        case .fail: return "fail"
        case .resume: return "resume"
        case .retry: return "be retried"
        case .reopen: return "be reopened"
        case .stop: return "be stopped"
        }
    }
}
