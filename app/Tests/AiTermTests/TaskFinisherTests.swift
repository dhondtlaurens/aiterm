import Testing
import Foundation
import Synchronization
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// A sleep the test ends by hand: each `tick()` lets one waiting poll go on.
actor Ticker {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var banked = 0
    func wait() async {
        if banked > 0 { banked -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func tick() {
        if waiting.isEmpty { banked += 1 } else { waiting.removeFirst().resume() }
    }
}

/// The time a publication reads: a watch's sleep moves it on by what it slept, a test by hand.
final class MergeClock: Sendable {
    private let at = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    private let naps = Mutex<[TimeInterval]>([])
    var now: Date { at.withLock { $0 } }
    var sleeps: [TimeInterval] { naps.withLock { $0 } }
    func pass(_ seconds: TimeInterval) { at.withLock { $0 = $0.addingTimeInterval(seconds) } }
    func slept(_ seconds: TimeInterval) { naps.withLock { $0.append(seconds) }; pass(seconds) }
}

/// finish_task as the app runs it: steps saved to the workspace as they complete, a merge end
/// watched until it merges, stopped by a takeover or a pause — never a second watch, push or request.
@MainActor @Suite(.blocking) struct TaskFinisherTests {
    let git = GitRunner.hermetic()

    final class Changed { var ids: [UUID] = [] }


    /// What a callback was handed, in order, from any thread.
    final class Recorded<Value: Sendable>: Sendable {
        private let values = Mutex<[Value]>([])
        var all: [Value] { values.withLock { $0 } }
        func append(_ value: Value) { values.withLock { $0.append(value) } }
    }

    /// Hermetic git whose every push times out before it reaches origin.
    struct PushTimesOut: GitRunning {
        let inner: any GitRunning = GitRunner.hermetic()
        func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
            guard args.contains("push") else { return try inner.run(args, in: dir, timeout: timeout, environment: environment) }
            throw GitError(args: args, code: 15, stderr: "git push timed out after \(timeout) s", timedOut: true)
        }
    }

    struct Setup {
        let store: WorkspaceStore, finisher: TaskFinisher, host: FakeMergeHost, ticker: Ticker, changed: Changed, clock: MergeClock
        let task: UUID, run: UUID, sha: String, origin: String, path: String
        let remotes: Recorded<RemoteInfo>, mergedOnHost: Recorded<UUID>, stopped: Recorded<String>
    }

    func setUp(end: TaskEnd, git finisherGit: (any GitRunning)? = nil, slices: Slices = OperatedWorld.profile.slices,
               connect: (@Sendable (RemoteInfo) throws -> any MergeRequestPublishing)? = nil) throws -> Setup {
        let fixture = try GitFixture.withOrigin(branch: "feat/pluto-231")
        var world = OperatedWorld(projectPath: fixture.path)
        let run = world.addRun(slices: slices)
        let task = world.addTask("PLUTO-231", run: run, state: .accepted, end: end, branch: "feat/pluto-231", acceptedSHA: fixture.sha)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = WorkspaceStore(file: StateStore(url: dir.appendingPathComponent("state.json")), saveDelay: .milliseconds(10))
        try store.load()
        let state = world.state
        store.mutate { $0 = state }
        let host = FakeMergeHost(), ticker = Ticker(), changed = Changed(), clock = MergeClock()
        let remotes = Recorded<RemoteInfo>(), mergedOnHost = Recorded<UUID>(), stopped = Recorded<String>()
        let finisher = TaskFinisher(store: store, git: finisherGit ?? git,
                                    connect: { remote in
                                        remotes.append(remote)
                                        return try connect?(remote) ?? host
                                    },
                                    now: { clock.now },
                                    sleep: { seconds in await ticker.wait(); clock.slept(seconds) })
        finisher.changed = { changed.ids.append($0) }
        finisher.mergedOnHost = { id, _ in mergedOnHost.append(id) }
        finisher.watchStopped = { _, why in stopped.append(why) }
        return Setup(store: store, finisher: finisher, host: host, ticker: ticker, changed: changed, clock: clock,
                     task: task, run: run, sha: fixture.sha, origin: fixture.origin, path: fixture.path,
                     remotes: remotes, mergedOnHost: mergedOnHost, stopped: stopped)
    }

    func operated(_ s: Setup) -> OperatedTask? { s.store.state.task(id: s.task)?.operated }

    @Test func aDraftMREndIsPushedOpenedSavedAndPublished() async throws {
        let s = try setUp(end: .draftMR)
        let result = await s.finisher.finish(s.task)
        #expect(result == TaskFinisher.Result(result: "published", reason: nil, mergeRequest: FakeMergeHost.url,
                                              pushedSHA: s.sha, merged: false, mergedSHA: nil))
        #expect(operated(s)?.state == .published)
        #expect(s.store.state.task(id: s.task)?.mr == MergeRequestRef(iid: 12, title: "PLUTO-231", url: FakeMergeHost.url))
        #expect(try git.run(["rev-parse", "refs/heads/feat/pluto-231"], in: s.origin) == s.sha)
        let saved = try StateStore(url: s.store.file.url).load()
        #expect(saved.task(id: s.task)?.operated?.publication?.mergeRequestNumber == 12, "each step is on disk")
        #expect(saved.task(id: s.task)?.operated?.state == .published)
        let again = await s.finisher.finish(s.task)
        #expect(again == result, "a repeat is answered from the record")
        #expect(s.host.log.filter { $0.hasPrefix("create") }.count == 1)
    }

    /// The host is the one the push goes to: origin's, never the branch's upstream remote.
    @Test func theHostAskedIsOrigins() async throws {
        let s = try setUp(end: .draftMR)
        try git.run(["remote", "add", "upstream", "git@github.com:someone-else/acme-web.git"], in: s.path)
        try git.run(["config", "branch.feat/pluto-231.remote", "upstream"], in: s.path)
        _ = await s.finisher.finish(s.task)
        #expect(s.remotes.all == [ProviderDetector.detect(remoteUrl: s.origin, repoPath: s.path)])
    }

    /// Two ready reads, `mergePoll` apart, before the merge; every wait between polls is `mergePoll`.
    @Test func aMergeEndWaitsThenMergesAndWakesTheOperator() async throws {
        let s = try setUp(end: .merge)
        s.host.update { $0.readiness = [.waiting("its pipeline is running"), .ready(head: s.sha)] }
        let first = await s.finisher.finish(s.task)
        #expect(first.result == "waitingToMerge")
        #expect(first.reason == "its pipeline is running")
        #expect(first.mergeRequest == FakeMergeHost.url && first.pushedSHA == s.sha && !first.merged)
        #expect(s.finisher.watching == [s.task])
        await s.ticker.tick()
        #expect(await eventually(describing: "the first ready read") { operated(s)?.publication?.readySince != nil })
        #expect(s.finisher.watching == [s.task], "a first ready read is confirmed before the merge")
        await s.ticker.tick()
        #expect(await eventually(describing: "the merge") { operated(s)?.state == .published })
        #expect(operated(s)?.publication?.mergedSHA == "5eed5eed")
        #expect(await eventually(describing: "the operator told") { s.changed.ids == [s.task] })
        #expect(s.host.log.last == "merge 12 at \(s.sha)")
        #expect(await eventually(describing: "the watch to end") { s.finisher.watching.isEmpty })
        #expect(s.clock.sleeps == [OperatorTiming.mergePoll, OperatorTiming.mergePoll])
    }

    @Test func aWatchEndsWhenTheWaitRunsOut() async throws {
        let s = try setUp(end: .merge)
        _ = await s.finisher.finish(s.task)
        s.clock.pass(OperatorTiming.mergeWait)
        await s.ticker.tick()
        #expect(await eventually(describing: "the watch to end") { s.finisher.watching.isEmpty })
        #expect(operated(s)?.publication?.problem?.hasPrefix("Still not mergeable after 60 minutes") == true)
        #expect(s.changed.ids == [s.task])
        #expect(!s.host.log.contains { $0.hasPrefix("merge") })
    }

    @Test func resumingTwiceWatchesOnce() async throws {
        let s = try setUp(end: .merge)
        _ = await s.finisher.finish(s.task)
        s.finisher.resumeWatching()
        s.finisher.resumeWatching()
        #expect(s.finisher.watching == [s.task])
        s.finisher.stopWatching(s.task)
        #expect(s.finisher.watching.isEmpty)
        s.finisher.resumeWatching()
        #expect(s.finisher.watching == [s.task], "a restart picks the wait up again from what was saved")
    }

    @Test func aTakeoverDuringTheWaitStopsItWithoutMerging() async throws {
        let s = try setUp(end: .merge)
        s.host.update { $0.readiness = [.waiting("its pipeline is running"), .ready(head: s.sha)] }
        _ = await s.finisher.finish(s.task)
        s.store.mutate { state in
            guard let i = state.tasks.firstIndex(where: { $0.id == s.task }) else { return }
            state.tasks[i].operated?.takenOver = true
            state.tasks[i].operated?.ownership += 1
        }
        await s.ticker.tick()
        #expect(await eventually(describing: "the watch to stop") { s.finisher.watching.isEmpty })
        #expect(!s.host.log.contains { $0.hasPrefix("merge") })
        #expect(operated(s)?.state == .accepted)
        let why = "You've taken PLUTO-231 over; it is published only once you hand it back."
        #expect(s.stopped.all == [why], "never silently: the reason is said")
        #expect(operated(s)?.publication?.problem == why)
        #expect(s.changed.ids.isEmpty)
    }

    /// The branch moved past the accepted commit while the merge waited: the reason is recorded, the
    /// operator told once, and nothing watches it again until its next finish_task.
    @Test func aBranchMovedDuringTheWaitStopsTheWatchAndSaysWhy() async throws {
        let s = try setUp(end: .merge)
        s.host.update { $0.readiness = [.waiting("its pipeline is running"), .ready(head: s.sha)] }
        _ = await s.finisher.finish(s.task)
        try git.run(["commit", "--allow-empty", "-q", "-m", "one more"], in: s.path)
        await s.ticker.tick()
        #expect(await eventually(describing: "the watch to stop") { s.finisher.watching.isEmpty })
        #expect(s.stopped.all.count == 1)
        #expect(s.stopped.all.first?.hasPrefix("feat/pluto-231 moved past the accepted commit") == true)
        #expect(operated(s)?.publication?.problem == s.stopped.all.first)
        #expect(try StateStore(url: s.store.file.url).load().task(id: s.task)?.operated?.publication?.problem == s.stopped.all.first)
        s.finisher.resumeWatching()
        #expect(s.finisher.watching.isEmpty, "a recorded problem waits for finish_task")
        #expect(!s.host.log.contains { $0.hasPrefix("merge") })
    }

    /// A takeover disarms a waiting merge for good: handed back, resumed or relaunched, nothing watches it
    /// until the operator's next finish_task, which starts the wait afresh.
    @Test func aTakeoverDisarmsTheWaitUntilTheNextFinish() async throws {
        let s = try setUp(end: .merge)
        _ = await s.finisher.finish(s.task)
        s.store.mutate { $0.updateOperated(s.task) { $0.takenOver = true; $0.ownership += 1 } }
        s.finisher.disarm(s.task, because: TaskFinisher.takenOverProblem)
        #expect(s.finisher.watching.isEmpty)
        #expect(operated(s)?.publication?.problem == TaskFinisher.takenOverProblem)
        s.store.mutate { $0.updateOperated(s.task) { $0.takenOver = false } }
        s.finisher.resumeWatching()
        #expect(s.finisher.watching.isEmpty)
        #expect(s.stopped.all.isEmpty && s.changed.ids.isEmpty, "you did it: no word to the operator from here")
        #expect(await s.finisher.finish(s.task).result == "waitingToMerge")
        #expect(s.finisher.watching == [s.task])
        #expect(operated(s)?.publication?.problem == nil)
    }

    /// A watch whose poll finds the operation paused stops there, before the host is asked anything.
    @Test func aWatchThatFindsTheRunPausedStopsWithoutActing() async throws {
        let s = try setUp(end: .merge)
        s.host.update { $0.readiness = [.waiting("its pipeline is running"), .ready(head: s.sha)] }
        _ = await s.finisher.finish(s.task)
        let asked = s.host.log
        s.store.mutate { state in state.runs[0].state = .paused; state.runs[0].intent = .paused }
        await s.ticker.tick()
        #expect(await eventually(describing: "the watch to stop") { s.finisher.watching.isEmpty })
        #expect(s.host.log == asked)
        #expect(s.changed.ids.isEmpty)
    }

    /// Your Pause stops the operation's watches; a paused operation is never watched again until it runs,
    /// and a poll already under way merges nothing.
    @Test func aPauseStopsTheWatchAndMergesNothing() async throws {
        let s = try setUp(end: .merge)
        s.host.update { $0.readiness = [.waiting("its pipeline is running"), .ready(head: s.sha)] }
        _ = await s.finisher.finish(s.task)
        s.store.mutate { state in state.runs[0].state = .paused; state.runs[0].intent = .paused }
        s.finisher.stopWatching(inRun: s.run)
        #expect(s.finisher.watching.isEmpty)
        s.finisher.resumeWatching()
        #expect(s.finisher.watching.isEmpty, "paused: nothing to watch")
        let again = await s.finisher.finish(s.task)
        #expect(again.result == "refused")
        #expect(again.reason == "The broadcast is paused; nothing is published until it runs again.")
        #expect(again.mergeRequest == FakeMergeHost.url && again.pushedSHA == s.sha, "a refusal says what was done so far")
        #expect(!s.host.log.contains { $0.hasPrefix("merge") })
        s.store.mutate { state in state.runs[0].state = .active; state.runs[0].intent = nil }
        s.finisher.resumeWatching()
        #expect(s.finisher.watching == [s.task], "Resume picks the wait up again")
    }

    /// The operator's retry after the daemon gave up on the first call (30 s) while a push or a create was
    /// still going: it waits for that one and answers what it did — one request, never two.
    @Test func twoCallsAtOnceShareOneRunAndOpenOneRequest() async throws {
        let s = try setUp(end: .draftMR)
        let gate = Ticker()
        s.host.update { $0.beforeCreate = { await gate.wait() } }
        let first = Task { await s.finisher.finish(s.task) }
        #expect(await eventually(describing: "the first call at the host's create") { s.host.log.contains { $0.hasPrefix("create") } })
        #expect(s.finisher.running == [s.task])
        let second = Task { await s.finisher.finish(s.task) }
        #expect(await eventually(describing: "the second call to join the first") { s.finisher.joined == 1 })
        await gate.tick()
        let (a, b) = (await first.value, await second.value)
        #expect(a == b)
        #expect(a.result == "published")
        #expect(s.host.log.filter { $0.hasPrefix("create") }.count == 1)
        #expect(s.host.log.filter { $0.hasPrefix("protection") }.count == 1, "pushed once")
        #expect(s.finisher.running.isEmpty)
    }

    /// A step that cannot be saved is the last: no request is opened for a push the workspace does not know of.
    @Test func aStepThatCannotBeSavedStopsBeforeTheNext() async throws {
        let s = try setUp(end: .draftMR)
        #expect(s.store.flush(), "the workspace saves at first")
        try FileManager.default.createDirectory(at: s.store.file.backupURL, withIntermediateDirectories: true)
        let result = await s.finisher.finish(s.task)
        #expect(result.result == "failed")
        #expect(result.reason == TaskFinisher.notSavedReason)
        #expect(result.pushedSHA == s.sha, "it says the push it made")
        #expect(s.host.log == ["protection feat/pluto-231"], "pushed, then stopped")
        #expect(operated(s)?.state == .accepted)
    }

    /// A push that ran out of time may have landed: the answer never says nothing was pushed.
    @Test func aPushThatTimedOutMayHaveLanded() async throws {
        let s = try setUp(end: .draftMR, git: PushTimesOut())
        let result = await s.finisher.finish(s.task)
        #expect(result.result == "failed")
        #expect(result.reason == "The push of feat/pluto-231 timed out, so the push may have landed; call finish_task again, which asks origin before it pushes.")
        #expect(s.host.log == ["protection feat/pluto-231"])
        #expect(operated(s)?.publication?.pushedSHA == nil)
    }

    @Test func aHostThatIsNotConnectedIsRefusedBeforeAnythingIsPushed() async throws {
        let s = try setUp(end: .draftMR, connect: { _ in throw MergeRequestSearch.Unavailable.notConnected(.gitLab) })
        let result = await s.finisher.finish(s.task)
        #expect(result == TaskFinisher.Result(result: "refused", reason: "acme-web has no connected code host.",
                                              mergeRequest: nil, pushedSHA: nil, merged: false, mergedSHA: nil))
        #expect((try? git.run(["rev-parse", "--verify", "--quiet", "refs/heads/feat/pluto-231"], in: s.origin)) == nil)
    }

    /// What the plan rules out is said as such, before any host is connected.
    @Test func aCommitEndIsRefusedWithoutAHost() async throws {
        let s = try setUp(end: .commit, connect: { _ in throw MergeRequestSearch.Unavailable.notConnected(.gitLab) })
        let result = await s.finisher.finish(s.task)
        #expect(result.result == "refused")
        #expect(result.reason == "PLUTO-231 ends in a commit: its plan opens no merge request, so there is nothing to finish.")
        #expect(s.remotes.all.isEmpty)
    }

    @Test func aStoppedOperationStaysUnpublishedAcrossARestart() async throws {
        let s = try setUp(end: .merge)
        s.store.mutate { state in state.runs[0].state = .stopped }
        let result = await s.finisher.finish(s.task)
        #expect(result.result == "refused")
        #expect(result.reason == "The broadcast was stopped; it publishes nothing.")
        s.finisher.resumeWatching()
        #expect(s.finisher.watching.isEmpty)
    }

    /// Merged on the host with a head nobody accepted: a question for you, never watched or retried.
    @Test func aForeignMergeIsPutToYouAndNotWatched() async throws {
        let s = try setUp(end: .merge)
        s.host.update { $0.readiness = [.merged(commit: "f00df00d", head: "0123456789abcdef")] }
        let result = await s.finisher.finish(s.task)
        #expect(result.result == "blocked")
        #expect(result.mergedSHA == "f00df00d" && !result.merged)
        #expect(result.reason == "PLUTO-231 was merged on the host at 0123456, not the accepted \(s.sha.prefix(7)): it holds commits that weren't accepted.")
        #expect(s.mergedOnHost.all == [s.task])
        #expect(s.finisher.watching.isEmpty)
        s.finisher.resumeWatching()
        #expect(s.finisher.watching.isEmpty)
        let again = await s.finisher.finish(s.task)
        #expect(again == result, "a repeat answers what happened")
        #expect(!s.host.log.contains { $0.hasPrefix("merge") })
    }

    // MARK: - The Merge slice and the local merge (spec §5)

    /// With the Merge slice off a merge end is refused before anything is pushed, and left for you once.
    @Test func aMergeWithTheSliceOffIsLeftForYou() async throws {
        let s = try setUp(end: .merge, slices: .none)
        let result = await s.finisher.finish(s.task)
        #expect(result.result == "refused" && result.reason == "The Merge slice is off for this broadcast.")
        _ = await s.finisher.finish(s.task)
        #expect(s.store.state.run(id: s.run)?.leftForYou.count == 1, "said once")
        #expect(operated(s)?.publication?.leftForYou == true)
        #expect(RunScheduler.isComplete(s.store.state.run(id: s.run)!, in: s.store.state))
        #expect(s.host.log.isEmpty && s.remotes.all.isEmpty, "no host asked")
        #expect(try git.run(["for-each-ref", "refs/heads/feat/pluto-231"], in: s.origin).isEmpty, "nothing pushed")
    }

    /// A local merge goes into the project's own checkout's default branch, never pushed: pushing it is left for you.
    @Test func aLocalMergeMergesIntoTheCheckoutAndLeavesThePushForYou() async throws {
        let s = try setUp(end: .mergeLocal)
        try git.run(["switch", "-q", "main"], in: s.path)
        let origin = try git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: s.origin)
        let result = await s.finisher.finish(s.task)
        let main = try git.run(["rev-parse", "main"], in: s.path)
        #expect(result == TaskFinisher.Result(result: "published", reason: nil, mergeRequest: nil, pushedSHA: nil, merged: true, mergedSHA: main))
        #expect(operated(s)?.state == .published)
        #expect(try git.run(["rev-parse", "main^2"], in: s.path) == s.sha)
        #expect(try git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: s.origin) == origin, "nothing pushed")
        #expect(s.remotes.all.isEmpty, "no host asked")
        #expect(s.store.state.run(id: s.run)?.leftForYou == ["Push main in acme-web: merged locally."])
        let saved = try StateStore(url: s.store.file.url).load()
        #expect(saved.task(id: s.task)?.operated?.publication?.merged == true, "on disk")
        #expect(await s.finisher.finish(s.task) == result, "a repeat is answered from the record")
        #expect(s.store.state.run(id: s.run)?.leftForYou.count == 1)
    }

    /// A checkout with uncommitted changes is refused, and nothing is left for you to push.
    @Test func aLocalMergeIntoADirtyCheckoutIsRefused() async throws {
        let s = try setUp(end: .mergeLocal)
        try git.run(["switch", "-q", "main"], in: s.path)
        try "x".write(toFile: s.path + "/notes.txt", atomically: true, encoding: .utf8)
        try git.run(["add", "notes.txt"], in: s.path)
        let result = await s.finisher.finish(s.task)
        #expect(result.result == "refused")
        #expect(result.reason == LocalMerge.Refusal.uncommittedChanges(s.path).localizedDescription)
        #expect(operated(s)?.state == .accepted)
        #expect(s.store.state.run(id: s.run)?.leftForYou.isEmpty == true)
    }
}

/// finish_task through the operator's tool and the controller: the publisher and the merge sleep are
/// its ports, your controls stop the watches, and a foreign merge asks you once.
@MainActor @Suite(.blocking) struct TaskFinisherControllerTests {
    let git = GitRunner.hermetic()

    func makeWorld(end: TaskEnd, host: FakeMergeHost, ticker: Ticker) throws -> (OperatorWorld, UUID, UUID, String) {
        let fixture = try GitFixture.withOrigin(branch: "feat/pluto-231")
        var operated = OperatedWorld(projectPath: fixture.path)
        let run = operated.addRun()
        let task = operated.addTask("PLUTO-231", run: run, state: .accepted, end: end, branch: "feat/pluto-231", acceptedSHA: fixture.sha)
        let world = try OperatorWorld(operated.state, git: git) { ports in
            ports.publisher = { _ in host }
            ports.mergeSleep = { _ in await ticker.wait() }
        }
        world.show([OperatorServiceFixtures.session("op", tag: run)])
        return (world, run, task, fixture.sha)
    }

    @Test func finishTaskAnswersWhatWasDone() async throws {
        let host = FakeMergeHost()
        let (world, run, task, sha) = try makeWorld(end: .draftMR, host: host, ticker: Ticker())
        let answer = await world.call(run, "finish_task", ["task": "PLUTO-231"])
        #expect(answer.value?["result"] == "published")
        #expect(answer.value?["pushedSHA"] == .string(sha))
        #expect(answer.value?["mergeRequest"] == .string(FakeMergeHost.url))
        #expect(world.task(task)?.operated?.state == .published)
        #expect(world.run(run)?.state == .complete, "its last task published completes the operation")
    }

    @Test func yourControlsStopTheWatchAndResumePicksItUp() async throws {
        let host = FakeMergeHost(), ticker = Ticker()
        let (world, run, task, _) = try makeWorld(end: .merge, host: host, ticker: ticker)
        #expect(await world.call(run, "finish_task", ["task": "PLUTO-231"]).value?["result"] == "waitingToMerge")
        #expect(world.controller.finisher.watching == [task])
        try world.controller.pause(run: run)
        #expect(world.controller.finisher.watching.isEmpty)
        try await world.controller.resume(run: run)
        #expect(world.controller.finisher.watching == [task])
        try await world.controller.end(run: run)
        #expect(world.controller.finisher.watching.isEmpty)
        world.controller.finisher.resumeWatching()
        #expect(world.controller.finisher.watching.isEmpty, "an ended operation is never watched again")
    }

    /// Take over, hand back, then a Resume of another operation and a relaunch: nothing merges until
    /// the operator's next finish_task, and then it does.
    @Test func aTakeoverHoldsTheMergeUntilTheNextFinish() async throws {
        let host = FakeMergeHost(), ticker = Ticker(), clock = MergeClock()
        let fixture = try GitFixture.withOrigin(branch: "feat/pluto-231")
        var operated = OperatedWorld(projectPath: fixture.path)
        let run = operated.addRun(), other = operated.addRun(.paused)
        let task = operated.addTask("PLUTO-231", run: run, state: .accepted, end: .merge, branch: "feat/pluto-231", acceptedSHA: fixture.sha)
        host.update { $0.readiness = [.waiting("its pipeline is running"), .ready(head: fixture.sha)] }
        let world = try OperatorWorld(operated.state, git: git) { ports in
            ports.publisher = { _ in host }
            ports.mergeSleep = { seconds in await ticker.wait(); clock.slept(seconds) }
            ports.publishNow = { clock.now }
        }
        world.show([OperatorServiceFixtures.session("op", tag: run), OperatorServiceFixtures.session("op2", window: "w2", tag: other)])
        #expect(await world.call(run, "finish_task", ["task": "PLUTO-231"]).value?["result"] == "waitingToMerge")
        try await world.controller.takeOver(task: task)
        #expect(world.controller.finisher.watching.isEmpty)
        try await world.controller.handBack(task: task)
        try await world.controller.resume(run: other)
        world.controller.start()
        defer { world.controller.stop() }
        #expect(world.controller.finisher.watching.isEmpty, "handed back, resumed, relaunched: still disarmed")
        await ticker.tick()
        await ticker.tick()
        for _ in 0..<50 { await Task.yield() }
        #expect(!host.log.contains { $0.hasPrefix("merge") })
        #expect(await world.call(run, "finish_task", ["task": "PLUTO-231"]).value?["result"] == "waitingToMerge")
        #expect(world.controller.finisher.watching == [task])
        await ticker.tick()
        await ticker.tick()
        #expect(await eventually(describing: "the merge") { world.task(task)?.operated?.state == .published })
        #expect(host.log.last == "merge 12 at \(fixture.sha)")
        #expect(await eventually(describing: "the operation to complete") { world.run(run)?.state == .complete })
    }

    /// The operator's tab gone, the poll is refused and the watch suspended; back, the reconciler
    /// makes the operation active again and the watch picks up.
    @Test func anOperatorOfflineAndBackIsWatchedAgain() async throws {
        let host = FakeMergeHost(), ticker = Ticker()
        let (world, run, task, _) = try makeWorld(end: .merge, host: host, ticker: ticker)
        #expect(await world.call(run, "finish_task", ["task": "PLUTO-231"]).value?["result"] == "waitingToMerge")
        world.show([])
        world.controller.reconcileTick()
        #expect(world.run(run)?.state == .operatorOffline)
        let asked = host.log
        await ticker.tick()
        #expect(await eventually(describing: "the watch to be suspended") { world.controller.finisher.watching.isEmpty })
        #expect(host.log == asked)
        #expect(world.task(task)?.operated?.publication?.problem == nil, "suspended, not stopped")
        world.show([OperatorServiceFixtures.session("op", tag: run)])
        world.controller.reconcileTick()
        #expect(world.run(run)?.state == .active)
        #expect(world.controller.finisher.watching == [task])
    }

    /// A branch moved during the wait: the operator is woken once with the reason, and neither a
    /// change in the run nor a relaunch watches it again.
    @Test func aBranchMovedWakesTheOperatorOnce() async throws {
        let host = FakeMergeHost(), ticker = Ticker()
        let (world, run, task, _) = try makeWorld(end: .merge, host: host, ticker: ticker)
        #expect(await world.call(run, "finish_task", ["task": "PLUTO-231"]).value?["result"] == "waitingToMerge")
        let projectId = try #require(world.task(task)?.projectId)
        let path = try #require(world.state.project(id: projectId)?.path)
        try git.run(["commit", "--allow-empty", "-q", "-m", "one more"], in: path)
        await world.controller.waker.lastSend?.value
        let before = world.daemon.requests("session.deliver").count
        await ticker.tick()
        #expect(await eventually(describing: "the watch to stop") { world.controller.finisher.watching.isEmpty })
        // The line names no task: run_status shows which, and the problem.
        let stopped = { world.daemon.requests("session.deliver").dropFirst(before).compactMap { $0.params["text"] as? String } }
        #expect(await eventually(describing: "the operator told") { stopped() == ["[AiTerm] one task’s merge watch stopped: call run_status"] })
        #expect(world.task(task)?.operated?.publication?.problem?.hasPrefix("feat/pluto-231 moved past") == true)
        world.controller.runChanged(run)
        world.controller.start()
        defer { world.controller.stop() }
        #expect(world.controller.finisher.watching.isEmpty)
        for _ in 0..<50 { await Task.yield() }
        await world.controller.waker.lastSend?.value
        #expect(stopped().count == 1, "told once")
    }

    @Test func aStartPicksUpTheWaitsSavedBefore() async throws {
        let host = FakeMergeHost(), ticker = Ticker()
        let (world, run, task, _) = try makeWorld(end: .merge, host: host, ticker: ticker)
        _ = await world.call(run, "finish_task", ["task": "PLUTO-231"])
        world.controller.finisher.stopWatching(task)
        world.controller.start()
        defer { world.controller.stop() }
        #expect(world.controller.finisher.watching == [task])
        try await world.controller.end(run: run)
        #expect(world.controller.finisher.watching.isEmpty)
    }

    @Test func aForeignMergeAsksYouOnce() async throws {
        let host = FakeMergeHost()
        host.update { $0.readiness = [.merged(commit: "f00df00d", head: "0123456789abcdef")] }
        let (world, run, task, _) = try makeWorld(end: .merge, host: host, ticker: Ticker())
        #expect(await world.call(run, "finish_task", ["task": "PLUTO-231"]).value?["result"] == "blocked")
        _ = await world.call(run, "finish_task", ["task": "PLUTO-231"])
        let questions = world.run(run)?.questions.filter { $0.task == task } ?? []
        #expect(questions.count == 1)
        #expect(questions.first?.text.hasPrefix("PLUTO-231 was merged on the host at 0123456") == true)
        #expect(world.task(task)?.operated?.flags.contains(.waitingOnYou) == true)
        #expect(world.notifications.posted.contains { $0.body.contains("merged on the host") }, "you are notified at once")
        #expect(world.controller.finisher.watching.isEmpty)
        #expect(world.run(run)?.state == .active, "an open question keeps the operation from completing")
    }
}

extension TaskFinisherTests {
    @Test func aProtectedTaskBranchSettlesAsLeftForYou() async throws {
        let s = try setUp(end: .draftMR)
        s.host.update { $0.protected["feat/pluto-231"] = "release policy" }
        let first = await s.finisher.finish(s.task)
        #expect(first.result == "refused")
        #expect(operated(s)?.publication?.leftForYou == true)
        #expect(RunScheduler.isComplete(s.store.state.run(id: s.run)!, in: s.store.state))
        #expect(await s.finisher.finish(s.task).result == "leftForYou")
        #expect(s.store.state.run(id: s.run)?.leftForYou.count == 1)
    }

    /// A protection lookup that failed can succeed on the next call: the task stays AiTerm's to publish.
    @Test func aFailedProtectionLookupIsNotLeftForYou() async throws {
        let s = try setUp(end: .draftMR)
        s.host.update { $0.protectionFails = true }
        #expect(await s.finisher.finish(s.task).result == "refused")
        #expect(operated(s)?.publication?.leftForYou != true)
        #expect(s.store.state.run(id: s.run)?.leftForYou.isEmpty == true)
        #expect(!RunScheduler.isComplete(s.store.state.run(id: s.run)!, in: s.store.state))
    }

    @Test func aProjectWithNoOriginSettlesAsLeftForYou() async throws {
        let s = try setUp(end: .draftMR)
        _ = try git.run(["remote", "remove", "origin"], in: s.path)
        #expect(await s.finisher.finish(s.task).result == "refused")
        #expect(operated(s)?.publication?.leftForYou == true)
        #expect(s.store.state.run(id: s.run)?.leftForYou.first?.contains("feat/pluto-231") == true)
        #expect(RunScheduler.isComplete(s.store.state.run(id: s.run)!, in: s.store.state))
    }
}
