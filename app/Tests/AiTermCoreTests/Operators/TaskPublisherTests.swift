import Foundation
import Testing
import Synchronization
@testable import AiTermCore
@testable import AiTermTestSupport

/// finish_task's steps against a real local origin and a scripted host, including the faults of
/// spec §12: a lost reply, a crash between steps, a takeover mid-way. None may push or open twice.
@Suite(.blocking) struct TaskPublisherTests {
    let git = GitRunner.hermetic()

    /// What `record` received, in order — the workspace's view of the publication. `failing`: a
    /// workspace that cannot save, so the first record throws. `crashAfter`: the app dies right after
    /// that many saves, so the save is kept and nothing after it runs; `host`'s log is noted then.
    final class Records: Sendable {
        struct NotSaved: Error {}
        struct Crashed: Error {}
        private let all = Mutex<[TaskPublication]>([])
        private let crashLog = Mutex<[String]?>(nil)
        let failing: Bool, crashAfter: Int?, host: FakeMergeHost?
        init(failing: Bool = false, crashAfter: Int? = nil, host: FakeMergeHost? = nil) {
            self.failing = failing; self.crashAfter = crashAfter; self.host = host
        }
        var list: [TaskPublication] { all.withLock { $0 } }
        var last: TaskPublication? { list.last }
        /// The host's log when the app died.
        var logAtCrash: [String]? { crashLog.withLock { $0 } }
        func append(_ p: TaskPublication) throws {
            if failing { throw NotSaved() }
            let saved = all.withLock { $0.append(p); return $0.count }
            if saved == crashAfter {
                crashLog.withLock { $0 = host?.log }
                throw Crashed()
            }
        }
    }

    /// A gate the test closes: true until `close()`, or after `opensFor` calls.
    final class Current: Sendable {
        private let calls = Mutex(0)
        let opensFor: Int
        init(opensFor: Int = .max) { self.opensFor = opensFor }
        func ask() -> Bool { calls.withLock { $0 += 1; return $0 <= opensFor } }
    }

    /// The time the publisher reads, moved on by the test.
    final class Clock: Sendable {
        private let at = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        var now: Date { at.withLock { $0 } }
        func pass(_ seconds: TimeInterval) { at.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    /// Hermetic git that counts the pushes asked of it, and can make the next one time out — before
    /// it reaches origin, or after it landed (only git is killed at the deadline; a hook or ssh can
    /// outlive it).
    final class PushGit: GitRunning {
        enum Fault { case none, timesOutUnlanded, landsThenTimesOut }
        private let inner: any GitRunning = GitRunner.hermetic()
        private let state: Mutex<(fault: Fault, pushes: Int)>
        init(_ fault: Fault = .none) { state = Mutex((fault, 0)) }
        var pushes: Int { state.withLock { $0.pushes } }

        func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
            guard args.contains("push") else { return try inner.run(args, in: dir, timeout: timeout, environment: environment) }
            let fault = state.withLock { s in s.pushes += 1; defer { s.fault = .none }; return s.fault }
            let timedOut = GitError(args: args, code: 15, stderr: "git push timed out after \(timeout) s", timedOut: true)
            if fault == .timesOutUnlanded { throw timedOut }
            let output = try inner.run(args, in: dir, timeout: timeout, environment: environment)
            if fault == .landsThenTimesOut { throw timedOut }
            return output
        }
    }

    struct Setup {
        var world: OperatedWorld
        let task: UUID, run: UUID, sha: String, origin: String, path: String
    }

    func setUp(end: TaskEnd, branch: String = "feat/pluto-231", key: String = "PLUTO-231") throws -> Setup {
        let fixture = try GitFixture.withOrigin(branch: branch)
        var world = OperatedWorld(projectPath: fixture.path)
        let run = world.addRun()
        let task = world.addTask(key, run: run, state: .accepted, end: end, branch: branch, acceptedSHA: fixture.sha)
        return Setup(world: world, task: task, run: run, sha: fixture.sha, origin: fixture.origin, path: fixture.path)
    }

    func advance(_ s: inout Setup, host: FakeMergeHost, restart: Bool = true, records: Records = Records(),
                 current: Current = Current(), parent: UUID? = nil, git pushGit: (any GitRunning)? = nil,
                 now: @escaping @Sendable () -> Date = Date.init, forReview: Bool = false) async throws -> TaskPublisher.Outcome {
        let publisher = TaskPublisher(repository: Repository(s.path, git: pushGit ?? git), host: host, now: now)
        let task = s.world.state.tasks.first { $0.id == s.task }!
        let context = TaskPublisher.Context(task: task, run: s.world.state.runs.first { $0.id == s.run }!,
                                            parent: parent.flatMap { id in s.world.state.tasks.first { $0.id == id } }, forReview: forReview)
        defer { if let last = records.last { s.world.update(s.task) { $0.publication = last } } }
        return try await publisher.advance(context, restart: restart,
                                           recheck: { current.ask() ? nil : PublicationGuard.changedMidway },
                                           record: { try records.append($0) })
    }

    func originHas(_ branch: String, in origin: String) -> String? {
        try? git.run(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], in: origin)
    }

    @Test func aDraftMRIsPushedThenOpenedAndEachStepRecorded() async throws {
        var s = try setUp(end: .draftMR)
        let host = FakeMergeHost(), records = Records()
        let outcome = try await advance(&s, host: host, records: records)
        let expected = TaskPublication(pushedSHA: s.sha, mergeRequestURL: FakeMergeHost.url, mergeRequestNumber: 12, targetBranch: "main",
                                       repository: FakeMergeHost.repository)
        #expect(outcome == .published(expected))
        #expect(records.list == [TaskPublication(pushedSHA: s.sha), expected])
        #expect(host.log == ["protection feat/pluto-231", "existing feat/pluto-231", "create feat/pluto-231 → main draft"])
        #expect(originHas("feat/pluto-231", in: s.origin) == s.sha)
    }

    @Test func aRepeatResumesAndDoesNothingTwice() async throws {
        var s = try setUp(end: .draftMR)
        let host = FakeMergeHost(), pushes = PushGit()
        _ = try await advance(&s, host: host, git: pushes)
        let again = try await advance(&s, host: host, git: pushes)
        guard case .published(let publication) = again else { Issue.record("\(again)"); return }
        #expect(publication.mergeRequestNumber == 12)
        #expect(host.log.count == 3, "no second protection check, lookup or request")
        #expect(pushes.pushes == 1)
    }

    @Test func aCrashBetweenPushAndRequestResumesAtTheRequest() async throws {
        var s = try setUp(end: .draftMR)
        let host = FakeMergeHost(.init(createFails: true)), records = Records()
        do { _ = try await advance(&s, host: host, records: records); Issue.record("the request should have failed") } catch is URLError {}
        #expect(records.list == [TaskPublication(pushedSHA: s.sha)], "the push is on record")
        host.update { $0.createFails = false }
        let outcome = try await advance(&s, host: host)
        #expect(outcome == .published(TaskPublication(pushedSHA: s.sha, mergeRequestURL: FakeMergeHost.url, mergeRequestNumber: 12, targetBranch: "main",
                                                      repository: FakeMergeHost.repository)))
    }

    @Test func aLostReplyAfterOpeningFindsTheRequestInsteadOfOpeningASecond() async throws {
        var s = try setUp(end: .draftMR)
        let host = FakeMergeHost(.init(loseCreateReply: true))
        do { _ = try await advance(&s, host: host); Issue.record("the reply should have been lost") } catch is URLError {}
        let outcome = try await advance(&s, host: host)
        guard case .published(let publication) = outcome else { Issue.record("\(outcome)"); return }
        #expect(publication.mergeRequestNumber == 12)
        #expect(host.log.filter { $0.hasPrefix("create") }.count == 1)
        #expect(host.log.filter { $0.hasPrefix("existing") }.count == 2, "the repeat looked for it first")
    }

    /// The app dies right after each save in turn; the next call resumes at the following step, and
    /// across them all the branch is pushed once, the request opened once and merged once.
    @Test(arguments: [TaskEnd.draftMR, .merge])
    func aCrashAfterAnySavedStepResumesAtTheNextAndRepeatsNone(end: TaskEnd) async throws {
        func publish(crashAfter: Int?) async throws -> (saves: Int, log: [String], pushes: Int, sha: String) {
            var s = try setUp(end: end)
            let host = FakeMergeHost(), records = Records(crashAfter: crashAfter, host: host), pushes = PushGit(), clock = Clock()
            host.update { $0.readiness = [.ready(head: s.sha)] }
            for _ in 0..<6 {
                do {
                    if case .published = try await advance(&s, host: host, records: records, git: pushes, now: { clock.now }) { break }
                } catch is Records.Crashed {
                    #expect(host.log == records.logAtCrash, "nothing done after the save the app died after, \(crashAfter ?? 0)")
                }
                clock.pass(OperatorTiming.mergePoll)
            }
            #expect(s.world.operated(s.task)?.publication?.mergeRequestNumber == 12, "crash after save \(crashAfter ?? 0)")
            return (records.list.count, host.log, pushes.pushes, s.sha)
        }
        let clean = try await publish(crashAfter: nil)
        #expect(clean.saves >= (end == .merge ? 4 : 2))
        for k in 1...clean.saves {
            let run = try await publish(crashAfter: k)
            #expect(run.pushes == 1, "crash after save \(k)")
            for step in ["protection", "create"] {
                #expect(run.log.filter { $0.hasPrefix(step) }.count == 1, "\(step), crash after save \(k)")
            }
            // The lookup before opening, and for a merge end the live read before merging.
            #expect(run.log.filter { $0.hasPrefix("existing") }.count == (end == .merge ? 2 : 1), "crash after save \(k)")
            #expect(run.log.filter { $0.hasPrefix("merge") }.count == (end == .merge ? 1 : 0), "crash after save \(k)")
            #expect(run.log.last == (end == .merge ? "merge 12 at \(run.sha)" : "create feat/pluto-231 → main draft"), "crash after save \(k)")
        }
    }

    @Test func aTakeoverMidwayStopsBeforeTheNextStep() async throws {
        var s = try setUp(end: .draftMR)
        let host = FakeMergeHost(), records = Records()
        let outcome = try await advance(&s, host: host, records: records, current: Current(opensFor: 1))
        #expect(outcome == .refused(PublicationGuard.changedMidway))
        #expect(records.list == [TaskPublication(pushedSHA: s.sha)])
        #expect(host.log == ["protection feat/pluto-231"], "no request looked up or opened after the takeover")
    }

    /// A pause or a takeover while the host is asked for an open request: nothing is opened.
    @Test func aChangeDuringTheLookupOpensNoRequest() async throws {
        var s = try setUp(end: .draftMR)
        let host = FakeMergeHost()
        let outcome = try await advance(&s, host: host, current: Current(opensFor: 2))
        #expect(outcome == .refused(PublicationGuard.changedMidway))
        #expect(host.log == ["protection feat/pluto-231", "existing feat/pluto-231"])
    }

    @Test func aChangeBeforeThePushPushesNothing() async throws {
        var s = try setUp(end: .draftMR)
        let host = FakeMergeHost(), records = Records()
        let outcome = try await advance(&s, host: host, records: records, current: Current(opensFor: 0))
        #expect(outcome == .refused(PublicationGuard.changedMidway))
        #expect(records.list.isEmpty)
        #expect(originHas("feat/pluto-231", in: s.origin) == nil)
    }

    /// A step that cannot be saved is the last: nothing is done that a restart would not know of.
    @Test func aStepThatCannotBeSavedStopsBeforeTheNext() async throws {
        var s = try setUp(end: .draftMR)
        let host = FakeMergeHost()
        do { _ = try await advance(&s, host: host, records: Records(failing: true)); Issue.record("the record should have failed") }
        catch is Records.NotSaved {}
        #expect(host.log == ["protection feat/pluto-231"], "pushed, then stopped")
        #expect(originHas("feat/pluto-231", in: s.origin) == s.sha)
    }

    @Test func aBranchTheHostProtectsIsNeverPushed() async throws {
        var s = try setUp(end: .draftMR)
        let host = FakeMergeHost(.init(protected: ["feat/pluto-231": "a ruleset’s pull request rule covers it"]))
        let outcome = try await advance(&s, host: host)
        #expect(outcome == .refused("feat/pluto-231 is protected on the host (a ruleset’s pull request rule covers it): AiTerm never pushes to a protected branch."))
        #expect(originHas("feat/pluto-231", in: s.origin) == nil)
        #expect(host.log == ["protection feat/pluto-231"])
    }

    @Test func aBranchWhoseProtectionCannotBeEstablishedIsNotPushed() async throws {
        var s = try setUp(end: .draftMR)
        let outcome = try await advance(&s, host: FakeMergeHost(.init(protectionFails: true)))
        #expect(outcome == .refused("AiTerm couldn’t tell whether feat/pluto-231 is protected on the host, so it pushed nothing: The host didn’t say which branches it protects."))
        #expect(originHas("feat/pluto-231", in: s.origin) == nil)
    }

    /// Any error from the protection check, not only `ProtectionUnknown`, leaves protection unknown.
    @Test func aHostErrorFromTheProtectionCheckPushesNothing() async throws {
        var s = try setUp(end: .draftMR)
        let host = FakeMergeHost(.init(protectionError: GitLabError.badResponse(502)))
        let outcome = try await advance(&s, host: host)
        #expect(outcome == .refused("AiTerm couldn’t tell whether feat/pluto-231 is protected on the host, so it pushed nothing: GitLab returned an error (HTTP 502). Try again."))
        #expect(originHas("feat/pluto-231", in: s.origin) == nil)
        #expect(host.log == ["protection feat/pluto-231"])
    }

    /// A push the rule refuses is a refusal with its reason, not an error to try again.
    @Test func aPushTheRuleRefusesIsRefusedWithItsReason() async throws {
        var s = try setUp(end: .draftMR)
        try git.run(["remote", "set-url", "--add", "--push", "origin", "/elsewhere"], in: s.path)
        let host = FakeMergeHost(), records = Records()
        let outcome = try await advance(&s, host: host, records: records)
        #expect(outcome == .refused(PublishRefusal.pushDestination("origin pushes to /elsewhere, not to where it is fetched from").localizedDescription))
        #expect(records.list.isEmpty)
        #expect(originHas("feat/pluto-231", in: s.origin) == nil)
        #expect(host.log == ["protection feat/pluto-231"])
    }

    /// Only git is killed at the deadline, so a timed-out push may have landed: the next call asks
    /// origin, finds the accepted commit there and goes on without pushing again.
    @Test func aTimedOutPushThatLandedIsNotPushedAgain() async throws {
        var s = try setUp(end: .draftMR)
        let host = FakeMergeHost(), records = Records(), git = PushGit(.landsThenTimesOut)
        let error = await #expect(throws: TaskPublisher.PushTimedOut.self) { _ = try await advance(&s, host: host, records: records, git: git) }
        #expect(error?.localizedDescription == "The push of feat/pluto-231 timed out and may have landed on origin; finish_task asks origin before it pushes again.")
        #expect(records.list.isEmpty)
        #expect(originHas("feat/pluto-231", in: s.origin) == s.sha, "it landed")
        let outcome = try await advance(&s, host: host, records: records, git: git)
        guard case .published(let publication) = outcome else { Issue.record("\(outcome)"); return }
        #expect(publication.pushedSHA == s.sha)
        #expect(records.list.first == TaskPublication(pushedSHA: s.sha))
        #expect(git.pushes == 1, "not pushed again")
    }

    @Test func aTimedOutPushThatDidNotLandIsPushedOnTheNextCall() async throws {
        var s = try setUp(end: .draftMR)
        let host = FakeMergeHost(), git = PushGit(.timesOutUnlanded)
        await #expect(throws: TaskPublisher.PushTimedOut.self) { _ = try await advance(&s, host: host, git: git) }
        #expect(originHas("feat/pluto-231", in: s.origin) == nil)
        let outcome = try await advance(&s, host: host, git: git)
        guard case .published = outcome else { Issue.record("\(outcome)"); return }
        #expect(originHas("feat/pluto-231", in: s.origin) == s.sha)
        #expect(git.pushes == 2)
    }

    @Test func aCommitEndPushesNothing() async throws {
        var s = try setUp(end: .commit)
        let outcome = try await advance(&s, host: FakeMergeHost())
        guard case .refused = outcome else { Issue.record("\(outcome)"); return }
        #expect(originHas("feat/pluto-231", in: s.origin) == nil)
    }

    @Test func aBranchThatMovedAfterAcceptanceIsRefused() async throws {
        var s = try setUp(end: .draftMR)
        try git.run(["commit", "--allow-empty", "-q", "-m", "more"], in: s.path)
        let outcome = try await advance(&s, host: FakeMergeHost())
        guard case .refused(let reason) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reason.hasPrefix("feat/pluto-231 moved past the accepted commit"))
        #expect(originHas("feat/pluto-231", in: s.origin) == nil)
    }

    /// A repeat on a task already published answers what was done, whatever has changed since —
    /// here the broadcast was stopped and the branch moved on.
    @Test func aPublishedTaskAnswersFromItsRecord() async throws {
        var s = try setUp(end: .draftMR)
        let done = TaskPublication(pushedSHA: s.sha, mergeRequestURL: FakeMergeHost.url, mergeRequestNumber: 12, targetBranch: "main")
        s.world.update(s.task) { $0.state = .published; $0.publication = done }
        if let index = s.world.state.runs.firstIndex(where: { $0.id == s.run }) { s.world.state.runs[index].state = .stopped }
        try git.run(["commit", "--allow-empty", "-q", "-m", "more"], in: s.path)
        let host = FakeMergeHost()
        #expect(try await advance(&s, host: host) == .published(done))
        #expect(host.log.isEmpty)
    }

    @Test func aMergedTaskAnswersFromItsRecordBeforeItIsPublished() async throws {
        var s = try setUp(end: .merge)
        let merged = TaskPublication(pushedSHA: s.sha, mergeRequestURL: FakeMergeHost.url, mergeRequestNumber: 12,
                                     targetBranch: "main", merged: true, mergedSHA: "5eed5eed")
        s.world.update(s.task) { $0.takenOver = true; $0.publication = merged }
        let host = FakeMergeHost()
        #expect(try await advance(&s, host: host) == .published(merged))
        #expect(host.log.isEmpty)
    }

    @Test func aMergeEndWaitsForTheHostThenMergesTheAcceptedCommit() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(), clock = Clock()
        host.update { $0.readiness = [.waiting("its pipeline is running"), .ready(head: s.sha)] }
        let first = try await advance(&s, host: host, now: { clock.now })
        guard case .waiting(_, let why) = first else { Issue.record("\(first)"); return }
        #expect(why == "its pipeline is running")
        clock.pass(OperatorTiming.mergePoll)
        let second = try await advance(&s, host: host, restart: false, now: { clock.now })
        guard case .waiting(let seen, let again) = second else { Issue.record("\(second)"); return }
        #expect(again == TaskPublisher.confirming)
        #expect(seen.readySince == clock.now)
        clock.pass(OperatorTiming.mergePoll)
        let third = try await advance(&s, host: host, restart: false, now: { clock.now })
        guard case .published(let publication) = third else { Issue.record("\(third)"); return }
        #expect(publication.merged)
        #expect(publication.mergedSHA == "5eed5eed")
        #expect(host.log.contains("create feat/pluto-231 → main"), "a merge end's request is no draft")
        #expect(host.log.last == "merge 12 at \(s.sha)")
    }

    /// CI may not have registered yet — GitHub with no checks, GitLab with no pipeline read ready —
    /// so the first ready is never merged, nor one read again within `mergePoll`.
    @Test func theFirstReadyIsNeverMerged() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(), clock = Clock()
        host.update { $0.readiness = [.ready(head: s.sha)] }
        let first = try await advance(&s, host: host, now: { clock.now })
        #expect(first == .waiting(try #require(s.world.operated(s.task)?.publication), TaskPublisher.confirming))
        clock.pass(OperatorTiming.mergePoll - 1)
        guard case .waiting = try await advance(&s, host: host, restart: false, now: { clock.now }) else { Issue.record("merged too soon"); return }
        #expect(!host.log.contains { $0.hasPrefix("merge") })
        clock.pass(1)
        guard case .published = try await advance(&s, host: host, restart: false, now: { clock.now }) else { Issue.record("not merged"); return }
        #expect(host.log.filter { $0.hasPrefix("merge") } == ["merge 12 at \(s.sha)"])
    }

    /// A ready, then a pipeline started, then ready again: the second ready is a first one again.
    @Test func aReadinessThatLapsedMustBeReadTwiceAgain() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(), clock = Clock()
        host.update { $0.readiness = [.ready(head: s.sha), .waiting("its pipeline is running"), .ready(head: s.sha)] }
        for _ in 0..<3 {
            guard case .waiting = try await advance(&s, host: host, restart: false, now: { clock.now }) else { Issue.record("merged"); return }
            clock.pass(OperatorTiming.mergePoll)
        }
        #expect(!host.log.contains { $0.hasPrefix("merge") })
        guard case .published = try await advance(&s, host: host, restart: false, now: { clock.now }) else { Issue.record("not merged"); return }
    }

    @Test func aHeadThatMovesBetweenTheTwoReadsIsNotMerged() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(), clock = Clock()
        host.update { $0.readiness = [.ready(head: s.sha), .ready(head: "0123456789abcdef0123456789abcdef01234567")] }
        _ = try await advance(&s, host: host, now: { clock.now })
        clock.pass(OperatorTiming.mergePoll)
        let outcome = try await advance(&s, host: host, restart: false, now: { clock.now })
        guard case .blocked(let publication, _) = outcome else { Issue.record("\(outcome)"); return }
        #expect(publication.readySince == nil)
        #expect(!host.log.contains { $0.hasPrefix("merge") })
    }

    @Test func aChangeBeforeTheMergeMergesNothing() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(), clock = Clock()
        host.update { $0.readiness = [.ready(head: s.sha)] }
        _ = try await advance(&s, host: host, now: { clock.now })
        clock.pass(OperatorTiming.mergePoll)
        let outcome = try await advance(&s, host: host, restart: false, current: Current(opensFor: 0), now: { clock.now })
        #expect(outcome == .refused(PublicationGuard.changedMidway))
        #expect(!host.log.contains { $0.hasPrefix("merge") })
    }

    @Test func aFailedPipelineIsAProblemThatTheOperatorsNextCallClears() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(.init(readiness: [.blocked("its pipeline failed")])), clock = Clock()
        let first = try await advance(&s, host: host, now: { clock.now })
        guard case .blocked(let publication, let why) = first else { Issue.record("\(first)"); return }
        #expect(why == "its pipeline failed")
        #expect(publication.problem == "its pipeline failed")
        host.update { $0.readiness = [.ready(head: s.sha)] }
        let second = try await advance(&s, host: host, restart: true, now: { clock.now })
        guard case .waiting(let cleared, _) = second else { Issue.record("\(second)"); return }
        #expect(cleared.problem == nil)
        clock.pass(OperatorTiming.mergePoll)
        let third = try await advance(&s, host: host, restart: false, now: { clock.now })
        guard case .published(let merged) = third else { Issue.record("\(third)"); return }
        #expect(merged.problem == nil)
        #expect(merged.merged)
    }

    @Test func theWaitIsBounded() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(.init(readiness: [.waiting("its pipeline is running")]))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await advance(&s, host: host, now: { start })
        guard case .waiting = first else { Issue.record("\(first)"); return }
        let late = try await advance(&s, host: host, restart: false, now: { start.addingTimeInterval(61 * 60) })
        guard case .blocked(_, let why) = late else { Issue.record("\(late)"); return }
        #expect(why == "Still not mergeable after 60 minutes: its pipeline is running.")
    }

    @Test func aHeadThatMovedOnTheHostIsNotMerged() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(.init(readiness: [.ready(head: "0123456789abcdef0123456789abcdef01234567")]))
        let outcome = try await advance(&s, host: host)
        guard case .blocked(_, let why) = outcome else { Issue.record("\(outcome)"); return }
        #expect(why == "The request's branch is at 0123456 on the host, not the accepted \(s.sha.prefix(7)).")
        #expect(!host.log.contains { $0.hasPrefix("merge") })
    }

    @Test func aRequestMergedBeforeTheAnswerCameIsRecordedNotMergedAgain() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(.init(readiness: [.merged(commit: "abc123", head: s.sha)]))
        let outcome = try await advance(&s, host: host)
        guard case .published(let publication) = outcome else { Issue.record("\(outcome)"); return }
        #expect(publication.mergedSHA == "abc123")
        #expect(publication.mergedHead == s.sha)
        #expect(!host.log.contains { $0.hasPrefix("merge") })
    }

    /// The operator's call while a first ready read is on record keeps it: no merge before
    /// `mergePoll` has passed, and none later than it either.
    @Test func aRestartInsideTheWindowNeitherMergesEarlyNorResetsTheConfirmation() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(), clock = Clock()
        host.update { $0.readiness = [.ready(head: s.sha)] }
        _ = try await advance(&s, host: host, now: { clock.now })
        let first = clock.now
        clock.pass(10)
        let early = try await advance(&s, host: host, restart: true, now: { clock.now })
        guard case .waiting(let publication, let why) = early else { Issue.record("\(early)"); return }
        #expect(why == TaskPublisher.confirming)
        #expect(publication.readySince == first, "the restart kept the first read")
        #expect(!host.log.contains { $0.hasPrefix("merge") })
        clock.pass(OperatorTiming.mergePoll - 10)
        guard case .published = try await advance(&s, host: host, restart: true, now: { clock.now }) else { Issue.record("not merged"); return }
        #expect(host.log.filter { $0.hasPrefix("merge") } == ["merge 12 at \(s.sha)"])
    }

    /// A first ready read from long ago — a pause, a quit, hours unpolled — is a first read again.
    @Test func aFirstReadyLongAgoIsAFirstReadAgain() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(), clock = Clock()
        host.update { $0.readiness = [.ready(head: s.sha)] }
        _ = try await advance(&s, host: host, now: { clock.now })
        clock.pass(TaskPublisher.readyCountsFor + 1)
        let stale = try await advance(&s, host: host, restart: false, now: { clock.now })
        guard case .waiting(let publication, let why) = stale else { Issue.record("\(stale)"); return }
        #expect(why == TaskPublisher.confirming)
        #expect(publication.readySince == clock.now)
        #expect(!host.log.contains { $0.hasPrefix("merge") })
        clock.pass(OperatorTiming.mergePoll)
        guard case .published = try await advance(&s, host: host, restart: false, now: { clock.now }) else { Issue.record("not merged"); return }
    }

    /// The hour is held: a first ready read after it has run out blocks rather than starting a confirmation.
    @Test func aFirstReadyAfterTheWaitRanOutBlocks() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(), clock = Clock()
        host.update { $0.readiness = [.waiting("its pipeline is running"), .ready(head: s.sha)] }
        _ = try await advance(&s, host: host, now: { clock.now })
        clock.pass(OperatorTiming.mergeWait)
        let late = try await advance(&s, host: host, restart: false, now: { clock.now })
        guard case .blocked(let publication, let why) = late else { Issue.record("\(late)"); return }
        #expect(why == "Still not mergeable after 60 minutes: the host called it mergeable only once the wait had run out, too late to read it twice.")
        #expect(publication.readySince == nil)
        #expect(!host.log.contains { $0.hasPrefix("merge") })
    }

    /// Someone retargets the request on the host between the two ready reads: a host merges into the
    /// target as it is now, so it is not merged.
    @Test func aRequestRetargetedOnTheHostIsNotMerged() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(), clock = Clock()
        host.update { $0.readiness = [.ready(head: s.sha)] }
        _ = try await advance(&s, host: host, now: { clock.now })
        host.update { $0.existing?.targetBranch = "release" }
        clock.pass(OperatorTiming.mergePoll)
        let outcome = try await advance(&s, host: host, restart: false, now: { clock.now })
        guard case .blocked(let publication, let why) = outcome else { Issue.record("\(outcome)"); return }
        #expect(why == "The request \(FakeMergeHost.url) targets release on the host now, not main: AiTerm never merges it there. Retarget it to main, then call finish_task again.")
        #expect(publication.readySince == nil)
        #expect(!host.log.contains { $0.hasPrefix("merge") })
    }

    @Test func aRequestClosedOnTheHostIsNotMerged() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(), clock = Clock()
        host.update { $0.readiness = [.ready(head: s.sha)] }
        _ = try await advance(&s, host: host, now: { clock.now })
        host.update { $0.existing = nil }
        clock.pass(OperatorTiming.mergePoll)
        let outcome = try await advance(&s, host: host, restart: false, now: { clock.now })
        #expect(outcome == .blocked(try #require(s.world.operated(s.task)?.publication),
                                    "The request \(FakeMergeHost.url) is no longer open on the host, so AiTerm did not merge it."))
        #expect(!host.log.contains { $0.hasPrefix("merge") })
    }

    /// Someone pushed more onto the request and merged it on the host: what was merged is recorded,
    /// never as this task's merge of its accepted commit, and a repeat answers it from the record.
    @Test func aRequestMergedOnTheHostWithAnotherHeadIsRecordedNotPublished() async throws {
        var s = try setUp(end: .merge)
        let other = "0123456789abcdef0123456789abcdef01234567"
        let host = FakeMergeHost(.init(readiness: [.merged(commit: "abc123", head: other)]))
        let outcome = try await advance(&s, host: host)
        let why = "PLUTO-231 was merged on the host at 0123456, not the accepted \(s.sha.prefix(7)): it holds commits that weren't accepted."
        guard case .blocked(let publication, let reason) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reason == why)
        #expect(!publication.merged)
        #expect(publication.mergedSHA == "abc123")
        #expect(publication.mergedHead == other)
        let calls = host.log.count
        #expect(try await advance(&s, host: host) == .blocked(publication, why))
        #expect(host.log.count == calls, "answered from the record")
    }

    @Test func aChildOfAParentMergedWithUnacceptedCommitsBlocks() async throws {
        var (s, parent) = try stacked(childEnd: .merge, parentEnd: .merge)
        s.world.update(parent) { $0.publication?.mergedSHA = "abc123"; $0.publication?.mergedHead = "0123456789abcdef0123456789abcdef01234567" }
        let host = FakeMergeHost()
        let outcome = try await advance(&s, host: host, parent: parent)
        guard case .blocked(_, let why) = outcome else { Issue.record("\(outcome)"); return }
        #expect(why == "PLUTO-230 was merged on the host with commits that weren't accepted: AiTerm publishes nothing on top of it.")
        #expect(host.log.isEmpty)
        #expect(originHas("feat/pluto-231", in: s.origin) == nil)
    }

    /// An open request from the branch into another branch than the task's is not AiTerm's to use:
    /// it is never merged as it is.
    @Test func anOpenRequestIntoAnotherBranchIsRefusedNotMerged() async throws {
        var s = try setUp(end: .merge)
        let elsewhere = MergeRequest(iid: 7, title: "PLUTO-231", sourceBranch: "feat/pluto-231", targetBranch: "develop",
                                     author: "ann", state: "opened", draft: false, url: "https://git.example.net/web/acme-web/-/merge_requests/7")
        let host = FakeMergeHost(.init(existing: elsewhere, readiness: [.ready(head: s.sha)])), clock = Clock()
        for _ in 0..<2 {
            let outcome = try await advance(&s, host: host, now: { clock.now })
            #expect(outcome == .refused("feat/pluto-231 already has an open request into develop, not main: https://git.example.net/web/acme-web/-/merge_requests/7. AiTerm never publishes through it as it is: retarget it to main or close it, then call finish_task again."))
            clock.pass(OperatorTiming.mergePoll)
        }
        #expect(!host.log.contains { $0.hasPrefix("create") || $0.hasPrefix("readiness") || $0.hasPrefix("merge") })
        #expect(s.world.operated(s.task)?.publication?.mergeRequestNumber == nil)
    }

    /// A parent with its request open on `feat/pluto-230`, and a child stacked on it in the same repository.
    func stacked(childEnd: TaskEnd, parentEnd: TaskEnd) throws -> (setup: Setup, parent: UUID) {
        var s = try setUp(end: parentEnd, branch: "feat/pluto-230", key: "PLUTO-230")
        try git.run(["switch", "-q", "-c", "feat/pluto-231"], in: s.path)
        try git.run(["commit", "--allow-empty", "-q", "-m", "PLUTO-231"], in: s.path)
        let childSHA = try git.run(["rev-parse", "HEAD"], in: s.path)
        try Repository(s.path, git: git).push(s.sha, as: "feat/pluto-230", defaultBranch: "main")
        let parent = s.task, parentSHA = s.sha, run = s.run
        s.world.update(parent) { $0.publication = TaskPublication(pushedSHA: parentSHA, mergeRequestURL: "https://git.example.net/web/acme-web/-/merge_requests/11", mergeRequestNumber: 11, targetBranch: "main", repository: FakeMergeHost.repository) }
        let child = s.world.addTask("PLUTO-231", run: run, state: .accepted, end: childEnd,
                                    dependsOn: [TaskDependency(task: parent, kind: .code)], branch: "feat/pluto-231", acceptedSHA: childSHA)
        return (Setup(world: s.world, task: child, run: s.run, sha: childSHA, origin: s.origin, path: s.path), parent)
    }

    @Test func aStackedDraftTargetsItsParentsBranch() async throws {
        var (s, parent) = try stacked(childEnd: .draftMR, parentEnd: .draftMR)
        let host = FakeMergeHost()
        let outcome = try await advance(&s, host: host, parent: parent)
        guard case .published(let publication) = outcome else { Issue.record("\(outcome)"); return }
        #expect(publication.targetBranch == "feat/pluto-230")
        #expect(host.log.last == "create feat/pluto-231 → feat/pluto-230 draft")
    }

    @Test func aStackedDraftsOpenRequestIntoTheDefaultBranchIsRefused() async throws {
        var (s, parent) = try stacked(childEnd: .draftMR, parentEnd: .draftMR)
        let host = FakeMergeHost(.init(existing: MergeRequest(iid: 12, title: "PLUTO-231", sourceBranch: "feat/pluto-231", targetBranch: "main",
                                                              author: "aiterm", state: "opened", draft: true, url: FakeMergeHost.url)))
        let outcome = try await advance(&s, host: host, parent: parent)
        guard case .refused(let reason) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reason.hasPrefix("feat/pluto-231 already has an open request into main, not feat/pluto-230"))
        #expect(!host.log.contains { $0.hasPrefix("create") || $0.hasPrefix("retarget") })
    }

    @Test func aStackedMergeWaitsForItsParentsMergeThenRetargetsAndMerges() async throws {
        var (s, parent) = try stacked(childEnd: .merge, parentEnd: .merge)
        let host = FakeMergeHost(), clock = Clock()
        host.update { $0.readiness = [.ready(head: s.sha)] }
        let first = try await advance(&s, host: host, parent: parent, now: { clock.now })
        guard case .waiting(_, let why) = first else { Issue.record("\(first)"); return }
        #expect(why == "waiting for PLUTO-230 to merge first")
        #expect(!host.log.contains { $0.hasPrefix("readiness") })
        s.world.update(parent) { $0.publication?.merged = true; $0.publication?.mergedSHA = "p4r3nt" }
        clock.pass(OperatorTiming.mergePoll)
        let second = try await advance(&s, host: host, restart: false, parent: parent, now: { clock.now })
        guard case .waiting(_, let confirming) = second else { Issue.record("\(second)"); return }
        #expect(confirming == TaskPublisher.confirming, "the first ready after the retarget is not merged")
        clock.pass(OperatorTiming.mergePoll)
        let third = try await advance(&s, host: host, restart: false, parent: parent, now: { clock.now })
        guard case .published(let publication) = third else { Issue.record("\(third)"); return }
        #expect(publication.targetBranch == "main")
        #expect(host.log.contains("retarget 12 → main"))
        #expect(host.log.last == "merge 12 at \(s.sha)")
        #expect(host.log.contains("create feat/pluto-231 → feat/pluto-230"))
    }

    @Test func aChangeBeforeTheRetargetRetargetsNothing() async throws {
        var (s, parent) = try stacked(childEnd: .merge, parentEnd: .merge)
        let host = FakeMergeHost()
        _ = try await advance(&s, host: host, parent: parent)
        s.world.update(parent) { $0.publication?.merged = true; $0.publication?.mergedSHA = "p4r3nt" }
        let outcome = try await advance(&s, host: host, restart: false, current: Current(opensFor: 0), parent: parent)
        #expect(outcome == .refused(PublicationGuard.changedMidway))
        #expect(!host.log.contains { $0.hasPrefix("retarget") })
    }

    @Test func aStackedDraftWhoseParentMergedOpensIntoTheDefaultBranch() async throws {
        var (s, parent) = try stacked(childEnd: .draftMR, parentEnd: .merge)
        s.world.update(parent) { $0.publication?.merged = true; $0.publication?.mergedSHA = "p4r3nt" }
        let host = FakeMergeHost()
        guard case .published(let publication) = try await advance(&s, host: host, parent: parent) else { Issue.record("not published"); return }
        #expect(publication.targetBranch == "main")
        #expect(host.log.last == "create feat/pluto-231 → main draft")
    }

    /// The parent merged before the child's request was opened: it opens into the default branch,
    /// where a retarget would take it — the parent's branch may be gone from the host.
    @Test func aStackedMergeWhoseParentMergedFirstOpensIntoTheDefaultBranch() async throws {
        var (s, parent) = try stacked(childEnd: .merge, parentEnd: .merge)
        s.world.update(parent) { $0.publication?.merged = true; $0.publication?.mergedSHA = "p4r3nt" }
        let host = FakeMergeHost()
        _ = try await advance(&s, host: host, parent: parent)
        #expect(host.log.contains("create feat/pluto-231 → main"))
        #expect(!host.log.contains { $0.hasPrefix("retarget") })
    }

    /// Its request was opened into the parent's branch and found again after a lost reply: the
    /// stacking rule's retarget applies to it.
    @Test func aStackedMergesFoundRequestIntoItsParentsBranchIsRetargetedOnceTheParentMerged() async throws {
        var (s, parent) = try stacked(childEnd: .merge, parentEnd: .merge)
        s.world.update(parent) { $0.publication?.merged = true; $0.publication?.mergedSHA = "p4r3nt" }
        let host = FakeMergeHost(.init(existing: MergeRequest(iid: 12, title: "PLUTO-231", sourceBranch: "feat/pluto-231", targetBranch: "feat/pluto-230",
                                                              author: "aiterm", state: "opened", draft: false, url: FakeMergeHost.url)))
        _ = try await advance(&s, host: host, parent: parent)
        #expect(!host.log.contains { $0.hasPrefix("create") })
        #expect(host.log.contains("retarget 12 → main"))
        #expect(s.world.operated(s.task)?.publication?.targetBranch == "main")
    }

    @Test func aRecordedRequestMergedIntoAnotherTargetIsForeign() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(), clock = Clock()
        _ = try await advance(&s, host: host, now: { clock.now })
        host.update {
            $0.existing = nil
            $0.readiness = [.merged(commit: "foreign", head: s.sha, target: "release")]
        }
        let outcome = try await advance(&s, host: host, now: { clock.now })
        guard case .blocked(let publication, let why) = outcome else { Issue.record("\(outcome)"); return }
        #expect(!publication.merged)
        #expect(publication.mergedSHA == "foreign" && publication.mergedHead == s.sha)
        #expect(publication.targetBranch == "release")
        #expect(why.contains("into release, not main"))
        let calls = host.log.count
        #expect(try await advance(&s, host: host, now: { clock.now }) == .blocked(publication, why))
        #expect(host.log.count == calls)
    }

    @Test func aMergedReadUsesTheLiveRequestAndFailsClosedWhenItIsGone() async throws {
        for target in ["release", nil] as [String?] {
            var s = try setUp(end: .merge)
            let host = FakeMergeHost(), clock = Clock()
            _ = try await advance(&s, host: host, now: { clock.now })
            host.update {
                if let target { $0.existing?.targetBranch = target } else { $0.existing = nil }
                $0.readiness = [.merged(commit: "foreign", head: s.sha)]
            }
            let outcome = try await advance(&s, host: host, now: { clock.now })
            guard case .blocked(let publication, _) = outcome else { Issue.record("\(outcome)"); continue }
            #expect(!publication.merged && publication.mergedSHA == "foreign")
            #expect(publication.targetBranch == target)
        }
    }

    @Test func aChildOfAParentMergedIntoAnotherTargetBlocksWithItsReason() async throws {
        var (s, parent) = try stacked(childEnd: .merge, parentEnd: .merge)
        let why = "PLUTO-230 was merged on the host into release, not main"
        s.world.update(parent) {
            $0.publication?.mergedSHA = "foreign"
            $0.publication?.mergedHead = $0.acceptance?.resultSHA
            $0.publication?.targetBranch = "release"
            $0.publication?.problem = why
        }
        let host = FakeMergeHost(), clock = Clock()
        let outcome = try await advance(&s, host: host, parent: parent, now: { clock.now })
        guard case .blocked(_, let reason) = outcome else { Issue.record("\(outcome)"); return }
        #expect(reason == "\(why): AiTerm publishes nothing on top of it.")
        #expect(host.log.isEmpty)
    }

    @Test func aMergedReadWithTheExpectedLiveTargetNeedsNoOpenRequest() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(), clock = Clock()
        _ = try await advance(&s, host: host, now: { clock.now })
        host.update {
            $0.existing = nil
            $0.readiness = [.merged(commit: "merged", head: s.sha, target: "main")]
        }
        let outcome = try await advance(&s, host: host, now: { clock.now })
        guard case .published(let publication) = outcome else { Issue.record("\(outcome)"); return }
        #expect(publication.merged && publication.targetBranch == "main")
        #expect(publication.mergedSHA == "merged" && publication.mergedHead == s.sha)
    }
    // MARK: - The Merge slice's floor and the local merge (spec §5)

    func thread(_ id: String, resolved: Bool) -> ReviewThread { ReviewThread(id: id, resolved: resolved, lastAuthor: "jan", lastBody: "Why?") }

    /// Every thread on the request must be resolved: an open one blocks the merge, read right before it.
    @Test func anOpenThreadBlocksTheMerge() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(), clock = Clock()
        host.update { $0.readiness = [.ready(head: s.sha)]; $0.threads = [thread("d1", resolved: false), thread("d2", resolved: true)] }
        _ = try await advance(&s, host: host, now: { clock.now })
        clock.pass(OperatorTiming.mergePoll)
        let blocked = try await advance(&s, host: host, restart: false, now: { clock.now })
        #expect(blocked == .blocked(s.world.operated(s.task)!.publication!, "1 review thread is still open on !12."))
        #expect(!host.log.contains { $0.hasPrefix("merge") })
        // Resolved, the operator's next call merges.
        host.update { $0.threads = [thread("d1", resolved: true), thread("d2", resolved: true)] }
        _ = try await advance(&s, host: host, restart: true, now: { clock.now })
        clock.pass(OperatorTiming.mergePoll)
        let merged = try await advance(&s, host: host, restart: false, now: { clock.now })
        guard case .published(let publication) = merged else { Issue.record("\(merged)"); return }
        #expect(publication.merged)
        #expect(host.log.suffix(2) == ["threads 12", "merge 12 at \(s.sha)"])
    }

    /// A request still a draft, from its review or someone's, is marked ready, only to merge it.
    @Test func aDraftRequestIsMarkedReadyToMerge() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(), clock = Clock()
        // Opened as a draft for its review, which has ended.
        _ = try await advance(&s, host: host, now: { clock.now }, forReview: true)
        #expect(host.log.last == "create feat/pluto-231 → main draft")
        host.update { $0.readiness = [.blocked("it is a draft"), .ready(head: s.sha)] }
        let first = try await advance(&s, host: host, restart: false, now: { clock.now })
        guard case .waiting = first else { Issue.record("\(first)"); return }
        #expect(host.log.contains("ready 12"))
        clock.pass(OperatorTiming.mergePoll)
        let merged = try await advance(&s, host: host, restart: false, now: { clock.now })
        guard case .published = merged else { Issue.record("\(merged)"); return }
        #expect(host.log.filter { $0 == "ready 12" }.count == 1)
        #expect(host.log.firstIndex(of: "ready 12")! < host.log.firstIndex(of: "merge 12 at \(s.sha)")!)
    }

    /// A request that is blocked for another reason than a draft is not marked ready.
    @Test func aBlockedRequestThatIsNoDraftIsLeftAsItIs() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(.init(readiness: [.blocked("its pipeline failed")]))
        let outcome = try await advance(&s, host: host)
        guard case .blocked(_, let why) = outcome else { Issue.record("\(outcome)"); return }
        #expect(why == "its pipeline failed")
        #expect(!host.log.contains { $0.hasPrefix("ready") })
    }

    /// A local merge asks no host and pushes nothing: the accepted commit is merged into the project's own
    /// checkout's default branch, and recorded as merged.
    @Test func aLocalMergeMergesTheAcceptedCommitAndPushesNothing() async throws {
        var s = try setUp(end: .mergeLocal)
        try git.run(["switch", "-q", "main"], in: s.path)
        let before = try git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: s.origin)
        let host = FakeMergeHost(), records = Records()
        let outcome = try await advance(&s, host: host, records: records)
        let main = try git.run(["rev-parse", "main"], in: s.path)
        #expect(outcome == .published(TaskPublication(targetBranch: "main", merged: true, mergedSHA: main)))
        #expect(records.list == [TaskPublication(targetBranch: "main", merged: true, mergedSHA: main)])
        #expect(try git.run(["rev-parse", "main^2"], in: s.path) == s.sha)
        #expect(host.log.isEmpty, "no host is asked")
        #expect(try git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: s.origin) == before, "nothing pushed")
        let again = try await advance(&s, host: host, records: records)
        #expect(again == outcome, "a repeat answers what was done")
    }

    @Test func aLocalMergeStopsWhenTheTaskChangedHands() async throws {
        var s = try setUp(end: .mergeLocal)
        try git.run(["switch", "-q", "main"], in: s.path)
        let main = try git.run(["rev-parse", "main"], in: s.path)
        let outcome = try await advance(&s, host: FakeMergeHost(), current: Current(opensFor: 0))
        #expect(outcome == .refused(PublicationGuard.changedMidway))
        #expect(try git.run(["rev-parse", "main"], in: s.path) == main)
    }

    @Test func aLocalMergeOffTheDefaultBranchIsRefused() async throws {
        var s = try setUp(end: .mergeLocal)
        // The fixture's checkout is on the task's branch, not the default one.
        let outcome = try await advance(&s, host: FakeMergeHost())
        #expect(outcome == .refused(LocalMerge.Refusal.notOnDefaultBranch(s.path, current: "feat/pluto-231", defaultBranch: "main").localizedDescription))
    }

    /// A draft is marked ready only when that is all that stops the merge: with a thread still open, or blocked for
    /// another reason, it stays a draft and no reviewer is notified.
    @Test func aDraftWithAnOpenThreadIsNotMarkedReady() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost()
        _ = try await advance(&s, host: host, forReview: true)
        host.update { $0.readiness = [.blocked("it is a draft")]; $0.threads = [thread("d1", resolved: false)] }
        let outcome = try await advance(&s, host: host, restart: false)
        guard case .blocked(_, let why) = outcome else { Issue.record("\(outcome)"); return }
        #expect(why == "1 review thread is still open on !12.")
        #expect(!host.log.contains("ready 12"), "the draft was not marked ready")
        #expect(!host.log.contains { $0.hasPrefix("merge") })
    }

    @Test func aDraftBlockedForAnotherReasonIsNotMarkedReady() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost()
        _ = try await advance(&s, host: host, forReview: true)
        host.update { $0.readiness = [.blocked("its pipeline failed")] }
        let outcome = try await advance(&s, host: host, restart: false)
        guard case .blocked(_, let why) = outcome else { Issue.record("\(outcome)"); return }
        #expect(why == "its pipeline failed")
        #expect(!host.log.contains("ready 12"))
    }

    /// A draft whose branch on origin is not the accepted commit is not marked ready: it would not merge.
    @Test func aDraftAtAnotherHeadIsNotMarkedReady() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost()
        _ = try await advance(&s, host: host, forReview: true)
        try git.run(["commit", "--allow-empty", "-q", "-m", "someone else"], in: s.path)
        try git.run(["push", "-q", "origin", "feat/pluto-231"], in: s.path)
        let moved = try git.run(["rev-parse", "HEAD"], in: s.path)
        try git.run(["update-ref", "refs/heads/feat/pluto-231", s.sha], in: s.path)
        host.update { $0.readiness = [.blocked("it is a draft")] }
        let outcome = try await advance(&s, host: host, restart: false)
        guard case .blocked(_, let why) = outcome else { Issue.record("\(outcome)"); return }
        #expect(why == "The request's branch is at \(moved.prefix(7)) on the host, not the accepted \(s.sha.prefix(7)).")
        #expect(!host.log.contains("ready 12"))
    }

    // MARK: - Gate C: the floor decides only on every thread, in the repository the request was opened in

    @Test func threadsThatCannotAllBeReadBlockTheMerge() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(), clock = Clock()
        host.update { $0.readiness = [.ready(head: s.sha)]; $0.reviewError = IncompleteRead("review threads") }
        _ = try await advance(&s, host: host, now: { clock.now })
        clock.pass(OperatorTiming.mergePoll)
        let blocked = try await advance(&s, host: host, restart: false, now: { clock.now })
        #expect(blocked == .blocked(s.world.operated(s.task)!.publication!, "AiTerm couldn’t read every review thread on !12."))
        #expect(!host.log.contains { $0.hasPrefix("merge") })
    }

    @Test func aDraftWhoseThreadsCannotAllBeReadIsNotMarkedReady() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost()
        _ = try await advance(&s, host: host, forReview: true)
        host.update { $0.readiness = [.blocked("it is a draft")]; $0.reviewError = URLError(.timedOut) }
        let outcome = try await advance(&s, host: host, restart: false)
        guard case .blocked(_, let why) = outcome else { Issue.record("\(outcome)"); return }
        #expect(why == "AiTerm couldn’t read every review thread on !12.")
        #expect(!host.log.contains("ready 12"))
    }

    @Test func aRequestIsActedOnOnlyInTheRepositoryItWasOpenedIn() async throws {
        var s = try setUp(end: .merge)
        let host = FakeMergeHost(), clock = Clock()
        _ = try await advance(&s, host: host, now: { clock.now })
        #expect(s.world.operated(s.task)?.publication?.repository == FakeMergeHost.repository, "kept when the request was opened")
        // The project's origin now resolves to another repository, which has a !12 of its own.
        let theirs = MergeRequest(iid: 12, title: "t", sourceBranch: "feat/pluto-231", targetBranch: "main", author: nil, state: "opened",
                                  draft: false, url: FakeMergeHost.url)
        let elsewhere = FakeMergeHost(.init(existing: theirs, readiness: [.ready(head: s.sha)], repository: "github.com/acme/elsewhere"))
        clock.pass(OperatorTiming.mergePoll)
        let moved = try await advance(&s, host: elsewhere, restart: false, now: { clock.now })
        #expect(moved == .refused("The project’s origin changed since !12 was opened, so AiTerm won’t act on it."))
        #expect(elsewhere.log.isEmpty, "the other repository is neither read nor written")
        // A request opened before AiTerm kept its repository is not acted on either.
        s.world.update(s.task) { $0.publication?.repository = nil }
        let old = try await advance(&s, host: host, restart: false, now: { clock.now })
        #expect(old == .refused("AiTerm didn’t keep which repository !12 was opened in, so it won’t act on it."))
    }
}
