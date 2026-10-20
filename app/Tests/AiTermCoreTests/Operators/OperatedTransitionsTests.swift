import Testing
import Foundation
@testable import AiTermCore

/// Spec §8's table, row by row, on one task: who may ask, from which state, in which run state,
/// and that every action repeated returns the task unchanged (spec §11).
@Suite struct OperatedTransitionsTests {
    typealias F = OperatorFixtures
    let head = "4f2a91c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6"
    /// M1's rules, named rather than `OperatorMilestone.current`'s: parts F and G raise that, and the
    /// rules that change with it are tested at each milestone below.
    let active = OperatedContext(runState: .active, retryLimit: 2, milestone: .m1)

    private func apply(_ action: OperatedAction, _ task: OperatedTask, by actor: OperatedActor = .operatorTool,
                       _ context: OperatedContext? = nil) throws(OperatedTransitionError) -> OperatedTask {
        try OperatedTransitions.apply(action, to: task, by: actor, context: context ?? active)
    }

    // MARK: planned → queued

    @Test func releasingARevisionQueuesItsPlannedTasks() throws {
        let task = F.operated("A", .planned, revision: 2)
        #expect(try apply(.release(revision: 2), task, by: .aiterm).state == .queued)
        #expect(try apply(.release(revision: 3), task, by: .aiterm).state == .queued)
    }

    @Test func anOlderRevisionDoesNotReleaseATaskChangedSince() {
        #expect(throws: OperatedTransitionError.notInRevision(released: 1, taskRevision: 2)) {
            try apply(.release(revision: 1), F.operated("A", .planned, revision: 2), by: .aiterm)
        }
    }

    @Test func onlyAiTermReleasesOrStarts() {
        let planned = F.operated("A", .planned)
        #expect(throws: OperatedTransitionError.wrongActor(action: "be released", actor: .operatorTool)) {
            try apply(.release(revision: 1), planned)
        }
        #expect(throws: OperatedTransitionError.wrongActor(action: "be released", actor: .you)) {
            try apply(.release(revision: 1), planned, by: .you)
        }
        #expect(throws: OperatedTransitionError.wrongActor(action: "start", actor: .operatorTool)) {
            try apply(.start(LaunchAttempt(number: 1, requestedAt: F.epoch)), F.operated("A", .queued))
        }
    }

    // MARK: queued → working

    @Test func startingSavesTheLaunchIntent() throws {
        let attempt = LaunchAttempt(number: 1, requestedAt: F.epoch)
        let started = try apply(.start(attempt), F.operated("A", .queued), by: .aiterm)
        #expect(started.state == .working && started.launch == attempt && started.started)
        #expect(try apply(.start(attempt), started, by: .aiterm) == started)
    }

    @Test(arguments: [OperatorRunState.planning, .paused, .operatorOffline, .complete, .stopped])
    func nothingStartsOutsideAnActiveRun(_ runState: OperatorRunState) {
        #expect(throws: OperatedTransitionError.runIs(runState)) {
            try apply(.start(LaunchAttempt(number: 1, requestedAt: F.epoch)), F.operated("A", .queued), by: .aiterm,
                      OperatedContext(runState: runState, retryLimit: 2))
        }
    }

    // MARK: working → accepted / noChange

    @Test func acceptingRecordsTheFullHeadAndSettlesTheFlags() throws {
        var task = F.operated("A", .working)
        task.flags = [.possiblyStalled, .waitingOnYou, .uncertain]
        let accepted = try apply(.accept(F.acceptance("4f2a91c"), branchHead: head), task)
        #expect(accepted.state == .accepted)
        #expect(accepted.acceptance?.resultSHA == head)
        #expect(accepted.acceptance?.checkOutput == "42 tests passed")
        #expect(accepted.flags == [.uncertain])
        #expect(try apply(.accept(F.acceptance(head), branchHead: head), accepted) == accepted, "the same SHA again is the earlier result")
    }

    @Test func aMovedBranchIsNotAccepted() {
        #expect(throws: OperatedTransitionError.notTheBranchHead(sha: "4f2a91c", head: "9999999aaaa")) {
            try apply(.accept(F.acceptance("4f2a91c"), branchHead: "9999999aaaa"), F.operated("A", .working))
        }
    }

    @Test(arguments: [("", "ok"), ("4f2a91c", ""), ("4f2a91c", "  \n")])
    func acceptingNeedsTheSHAAndTheCheckOutput(_ sha: String, _ check: String) {
        #expect(throws: OperatedTransitionError.missingEvidence) {
            try apply(.accept(F.acceptance(sha, check: check), branchHead: head), F.operated("A", .working))
        }
    }

    /// M1: once a `code` dependent started, the parent cannot be accepted again on another SHA.
    @Test func reacceptingOnAnotherSHAIsRefusedOnceACodeDependentStarted() throws {
        let accepted = try apply(.accept(F.acceptance("4f2a91c"), branchHead: head), F.operated("A", .working))
        let newHead = "abcdef0123456789"
        let moved = try apply(.accept(F.acceptance("abcdef0"), branchHead: newHead), accepted)
        #expect(moved.acceptance?.resultSHA == newHead, "no dependent started: the new SHA replaces the old")
        #expect(throws: OperatedTransitionError.reacceptAfterDependentStarted) {
            try apply(.accept(F.acceptance("abcdef0"), branchHead: newHead), accepted,
                      OperatedContext(runState: .active, retryLimit: 2, codeDependentStarted: true, milestone: .m1))
        }
    }

    /// M3 lifts that rule (spec §8): a parent accepted again replaces what its dependents built on, and a
    /// published task is accepted again on a new commit for `finish_task` to push. Before M3 a published
    /// task is never accepted again.
    @Test func fromM3AParentIsAcceptedAgainAfterItsDependentStartedAndAfterItWasPublished() throws {
        let m3 = OperatedContext(runState: .active, retryLimit: 2, codeDependentStarted: true, milestone: .m3)
        let accepted = try apply(.accept(F.acceptance("4f2a91c"), branchHead: head), F.operated("A", .working), m3)
        let newHead = "abcdef0123456789"
        #expect(try apply(.accept(F.acceptance("abcdef0"), branchHead: newHead), accepted, m3).acceptance?.resultSHA == newHead)
        var published = accepted
        published.state = .published
        let again = try apply(.accept(F.acceptance("abcdef0"), branchHead: newHead), published, m3)
        #expect(again.state == .accepted && again.acceptance?.resultSHA == newHead)
        #expect(try apply(.accept(F.acceptance("4f2a91c"), branchHead: head), published, m3) == published, "the same commit is a repeat")
        #expect(throws: OperatedTransitionError.notAllowed(action: "be accepted", from: .published)) {
            try apply(.accept(F.acceptance("abcdef0"), branchHead: newHead), published)
        }
    }

    /// Spec §11: a lost reply is asked again, and the branch may have moved since the first acceptance.
    @Test func aRepeatedAcceptanceIsTheEarlierResultEvenAfterTheBranchMoved() throws {
        let accepted = try apply(.accept(F.acceptance("4f2a91c"), branchHead: head), F.operated("A", .working))
        let moved = "abcdef0123456789"
        #expect(try apply(.accept(F.acceptance("4f2a91c"), branchHead: moved), accepted) == accepted)
        #expect(throws: OperatedTransitionError.notTheBranchHead(sha: "9999999", head: moved)) {
            try apply(.accept(F.acceptance("9999999"), branchHead: moved), accepted)
        }
    }

    @Test func noChangeIsAnEnd() throws {
        let done = try apply(.noChange(note: "already fixed"), F.operated("A", .working))
        #expect(done.state == .noChange)
        #expect(try apply(.noChange(note: nil), done) == done)
        #expect(throws: OperatedTransitionError.notAllowed(action: "end with no change", from: .queued)) {
            try apply(.noChange(note: nil), F.operated("A", .queued))
        }
    }

    /// The Operator's outcome is its look at the result: a drift AiTerm flagged is done with.
    @Test func anEndClearsABranchDrift() throws {
        var drifted = F.operated("A", .working)
        drifted.branchDrift = BranchDrift(source: .head, branch: "fix/mine", sha: nil, found: "Its worktree is on branch fix/mine.")
        #expect(try apply(.noChange(note: nil), drifted).branchDrift == nil)
        #expect(try apply(.block(reason: "it drifted"), drifted).branchDrift != nil, "a block leaves it for the resume")
    }

    // MARK: blocked, failed, retries

    @Test func blockingAndResumingKeepTheSameWorker() throws {
        let blocked = try apply(.block(reason: "needs the API key"), F.operated("A", .working))
        #expect(blocked.state == .blocked && blocked.blockedReason == "needs the API key")
        #expect(try apply(.block(reason: "needs the API key"), blocked) == blocked)
        let resumed = try apply(.resume, blocked)
        #expect(resumed.state == .working && resumed.blockedReason == nil)
        #expect(try apply(.resume, resumed) == resumed)
    }

    /// A task blocked for its runtime is resumed with a fresh allowance; one blocked for another reason keeps the time it used.
    @Test func resumingATaskBlockedForItsRuntimeGrantsAFreshAllowance() throws {
        let limit: TimeInterval = 90 * 60
        let context = OperatedContext(runState: .active, retryLimit: 2, milestone: .m1, runtimeLimit: limit)
        var spent = F.operated("A", .working)
        spent.runtimeUsed = limit
        let reason = try #require(OperatedTransitions.limitReason(for: spent))
        let blocked = try apply(.block(reason: reason), spent, by: .aiterm, context)
        #expect(blocked.runtimeUsed == limit, "what it used is still shown while it is blocked")
        let resumed = try apply(.resume, blocked, context)
        #expect(resumed.state == .working && resumed.runtimeUsed == 0)
        #expect(try apply(.resume, resumed, context) == resumed)

        var partway = F.operated("B", .working)
        partway.runtimeUsed = 30 * 60
        let other = try apply(.block(reason: "needs a key"), partway, context)
        #expect(try apply(.resume, other, context).runtimeUsed == 30 * 60)
    }

    /// A task blocked before it ever ran — upstream failed, then retried — waits its turn again.
    @Test func resumingATaskThatNeverRanQueuesIt() throws {
        var task = F.operated("B", .blocked, launched: false)
        task.blockedReason = "upstream failed: A"
        let queued = try apply(.resume, task)
        #expect(queued.state == .queued)
        #expect(try apply(.resume, queued) == queued, "a repeated resume is the earlier result")
    }

    /// Resume returns a task to the state it was blocked from: a retried task keeps its launch, but
    /// blocked while queued it has no session to continue.
    @Test func resumeReturnsATaskToWhereItWasBlockedFrom() throws {
        let failed = try apply(.fail(reason: "tests red"), F.operated("A", .working))
        let retried = try apply(.retry, failed)
        #expect(retried.started)
        let blocked = try apply(.block(reason: "limits"), retried, by: .aiterm)
        #expect(blocked.blockedFrom == .queued)
        let resumed = try apply(.resume, blocked)
        #expect(resumed.state == .queued && resumed.blockedFrom == nil)
        #expect(try apply(.resume, resumed) == resumed)

        let working = try apply(.block(reason: "needs a key"), F.operated("A", .working))
        #expect(working.blockedFrom == .working)
        let again = try apply(.block(reason: "other"), working, by: .aiterm)
        #expect(again.blockedFrom == .working, "blocking a blocked task keeps where it came from")
        #expect(try apply(.resume, again).state == .working)
    }

    /// What failed is kept through the retry and the start that follows it — a retried worker is told —
    /// and forgotten once the task is accepted or ends with no change.
    @Test func whatFailedIsKeptThroughARetryAndItsStartAndClearedAtAnEnd() throws {
        let failed = try apply(.fail(reason: "tests red"), F.operated("A", .working))
        #expect(failed.lastFailure == "tests red")
        let retried = try apply(.retry, failed)
        #expect(retried.blockedReason == nil && retried.lastFailure == "tests red")
        let started = try apply(.start(LaunchAttempt(number: 2, requestedAt: Date(timeIntervalSince1970: 5))), retried, by: .aiterm)
        #expect(started.state == .working && started.blockedReason == nil && started.lastFailure == "tests red")
        let done = try apply(.noChange(note: nil), started)
        #expect(done.lastFailure == nil)
        let accepted = try apply(.accept(TaskAcceptance(resultSHA: "abc1234", prerequisiteSHAs: [], checkOutput: "ok", note: nil, at: Date()),
                                         branchHead: "abc1234"), started)
        #expect(accepted.lastFailure == nil)
    }

    @Test func onlyAiTermBlocksAQueuedOrFailedTask() throws {
        #expect(try apply(.block(reason: "limits"), F.operated("A", .failed), by: .aiterm).state == .blocked)
        #expect(throws: OperatedTransitionError.notAllowed(action: "be blocked", from: .queued)) {
            try apply(.block(reason: "x"), F.operated("A", .queued))
        }
    }

    @Test func aFailedTaskIsRetriedWhileRetriesAreLeft() throws {
        let failed = try apply(.fail(reason: "tests red"), F.operated("A", .working))
        #expect(failed.state == .failed && failed.blockedReason == "tests red")
        let once = try apply(.retry, failed)
        #expect(once.state == .queued && once.retriesUsed == 1 && once.blockedReason == nil)
        #expect(try apply(.retry, once) == once, "a repeated retry is the earlier result")
        var spent = failed
        spent.retriesUsed = 2
        #expect(throws: OperatedTransitionError.noRetriesLeft(limit: 2)) { try apply(.retry, spent) }
    }

    @Test func limitsSayWhyAiTermBlocks() {
        var failed = F.operated("A", .failed)
        failed.retriesUsed = 2
        #expect(OperatedTransitions.limitReason(for: failed) != nil)
        failed.retriesUsed = 1
        #expect(OperatedTransitions.limitReason(for: failed) == nil)
        var working = F.operated("A", .working)
        working.runtimeUsed = 90 * 60
        #expect(OperatedTransitions.limitReason(for: working) != nil)
        working.runtimeUsed = 89 * 60
        #expect(OperatedTransitions.limitReason(for: working) == nil)
    }

    /// A worker that finished and waits for review or acceptance is never blocked for its time: only a
    /// worker still at work runs out of it.
    @Test func aTaskReadyForAcceptanceIsNeverBlockedForItsRuntime() {
        var working = F.operated("A", .working)
        working.runtimeUsed = 120 * 60
        #expect(OperatedTransitions.limitReason(for: working, readyForAcceptance: true) == nil)
        #expect(OperatedTransitions.limitReason(for: working, readyForAcceptance: false) != nil)
        var failed = F.operated("B", .failed)
        failed.retriesUsed = 2
        #expect(OperatedTransitions.limitReason(for: failed, readyForAcceptance: true) != nil, "retries are a limit of their own")
    }

    // MARK: run state and takeover

    /// Spec §9: a paused, offline or stopped run refuses the operator's mutations; a complete one
    /// still takes them.
    @Test(arguments: [OperatorRunState.planning, .paused, .operatorOffline, .stopped])
    func theOperatorsMutationsNeedAnActiveRun(_ runState: OperatorRunState) {
        #expect(throws: OperatedTransitionError.runIs(runState)) {
            try apply(.fail(reason: "x"), F.operated("A", .working), OperatedContext(runState: runState, retryLimit: 2))
        }
    }

    @Test func aCompleteRunStillTakesAnAcceptance() throws {
        let accepted = try apply(.accept(F.acceptance(head), branchHead: head), F.operated("A", .working),
                                 OperatedContext(runState: .complete, retryLimit: 2))
        #expect(accepted.state == .accepted)
    }

    @Test func aTakenOverTaskRefusesTheOperatorButNotYou() throws {
        var task = F.operated("A", .working)
        task.takenOver = true
        #expect(throws: OperatedTransitionError.takenOver) { try apply(.fail(reason: "x"), task) }
        #expect(throws: OperatedTransitionError.takenOver) { try apply(.block(reason: "x"), task, by: .aiterm) }
        #expect(try apply(.stop, task, by: .you).state == .stopped)
    }

    // MARK: published, stopped

    @Test func publishingCarriesOutADraftMROrAMergeFromM3Only() throws {
        let m3 = OperatedContext(runState: .active, retryLimit: 2, milestone: .m3)
        var task = F.operated("A", .accepted, end: .merge)
        task.acceptance = F.acceptance(head)
        let publication = TaskPublication(pushedSHA: head, mergeRequestURL: "https://example.net/mr/1")
        let published = try apply(.publish(publication), task, m3)
        #expect(published.state == .published && published.publication == publication)
        #expect(try apply(.publish(publication), published, m3) == published)
        #expect(throws: OperatedTransitionError.notInThisMilestone(.merge)) { try apply(.publish(publication), task) }
        #expect(throws: OperatedTransitionError.publishedSHANotAccepted("0000000ff")) {
            try apply(.publish(TaskPublication(pushedSHA: "0000000ff")), task, m3)
        }
        var commit = task
        commit.end = .commit
        #expect(throws: OperatedTransitionError.endIsCommit) { try apply(.publish(publication), commit, m3) }
    }

    @Test(arguments: [OperatedState.planned, .queued, .working, .blocked, .failed])
    func youStopAnyOpenTask(_ state: OperatedState) throws {
        let stopped = try apply(.stop, F.operated("A", state), by: .you, OperatedContext(runState: .paused, retryLimit: 2, milestone: .m1))
        #expect(stopped.state == .stopped)
        #expect(try apply(.stop, stopped, by: .you) == stopped)
    }

    /// An accepted task still waiting on its end is yours to stop; one whose end was its commit has ended.
    @Test func anAcceptedTaskIsStoppedOnlyWhileItsEndIsAhead() throws {
        var waiting = F.operated("A", .accepted)
        waiting.end = .draftMR
        #expect(try apply(.stop, waiting, by: .you).state == .stopped)
        var committed = waiting
        committed.end = .commit
        #expect(throws: OperatedTransitionError.notAllowed(action: "be stopped", from: .accepted)) {
            try apply(.stop, committed, by: .you)
        }
    }

    @Test(arguments: [OperatedState.noChange, .published])
    func anEndedTaskCannotBeStopped(_ state: OperatedState) {
        #expect(throws: OperatedTransitionError.notAllowed(action: "be stopped", from: state)) {
            try apply(.stop, F.operated("A", state), by: .you)
        }
    }

    @Test func refusalsReadAsTheToolsAnswer() {
        #expect(OperatedTransitionError.notAllowed(action: "be stopped", from: .accepted).description == "A task that is accepted can't be stopped.")
        #expect(OperatedTransitionError.runIs(.paused).description == "The broadcast is paused.")
    }

    @Test func shortAndFullSHAsNameOneCommit() {
        #expect(OperatedTransitions.sameCommit("4F2A91C", head))
        #expect(!OperatedTransitions.sameCommit("4f2a91", head), "six characters is too short to trust")
        #expect(!OperatedTransitions.sameCommit("", ""))
        #expect(!OperatedTransitions.sameCommit("4f2a91d", head))
    }
}
