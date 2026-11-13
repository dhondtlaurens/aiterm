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
        /// How many times the finisher asked the login shell again (`TaskFinisher.refreshLogin`).
        let forgotten: Recorded<Void>
    }

    func setUp(end: TaskEnd, git finisherGit: (any GitRunning)? = nil, slices: Slices = OperatedWorld.profile.slices,
               connect: (@Sendable (RemoteInfo) throws -> any MergeRequestPublishing)? = nil,
               work: OperatorWork = OperatorWork()) throws -> Setup {
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
                                    sleep: { seconds in await ticker.wait(); clock.slept(seconds) }, work: work)
        let forgotten = Recorded<Void>()
        finisher.refreshLogin = { forgotten.append(()) }
        finisher.changed = { changed.ids.append($0) }
        finisher.mergedOnHost = { id, _ in mergedOnHost.append(id) }
        finisher.watchStopped = { _, why in stopped.append(why) }
        return Setup(store: store, finisher: finisher, host: host, ticker: ticker, changed: changed, clock: clock,
                     task: task, run: run, sha: fixture.sha, origin: fixture.origin, path: fixture.path,
                     remotes: remotes, mergedOnHost: mergedOnHost, stopped: stopped, forgotten: forgotten)
    }

    func operated(_ s: Setup) -> OperatedTask? { s.store.state.task(id: s.task)?.operated }

    @Test func aDraftMREndIsPushedOpenedSavedAndPublished() async throws {
        let s = try setUp(end: .draftMR)
        let result = await s.finisher.finish(s.task)
        #expect(result == TaskFinisher.Result(result: .published, reason: nil, mergeRequest: FakeMergeHost.url,
                                              pushedSHA: s.sha, merged: false, mergedSHA: nil, draftNote: "MR !12 opened as a draft"))
        #expect(operated(s)?.state == .published)
        #expect(s.store.state.task(id: s.task)?.mr == MergeRequestRef(iid: 12, title: "PLUTO-231", url: FakeMergeHost.url))
        #expect(try git.run(["rev-parse", "refs/heads/feat/pluto-231"], in: s.origin) == s.sha)
        let saved = try StateStore(url: s.store.file.url).load()
        #expect(saved.task(id: s.task)?.operated?.publication?.mergeRequestNumber == 12, "each step is on disk")
        #expect(saved.task(id: s.task)?.operated?.state == .published)
        let again = await s.finisher.finish(s.task)
        var recorded = result
        recorded.draftNote = nil
        #expect(again == recorded, "a repeat is answered from the record, which did nothing to the draft")
        #expect(s.host.log.filter { $0.hasPrefix("create") }.count == 1)
    }

    /// `finish_task` says what it did to the request's draft state, so the Operator needn't ask the host.
    @Test func finishSaysWhetherTheDraftChanged() async throws {
        // A merge end opens a request that is ready, and waits for the host.
        let merge = try setUp(end: .merge)
        let opened = await merge.finisher.finish(merge.task)
        #expect(opened.result == .waitingToMerge && opened.draftNote == "MR !12 opened, ready")

        // A draft the host already has, which nothing else stops, is marked ready to merge it.
        let ready = try setUp(end: .merge)
        ready.host.update {
            $0.existing = MergeRequest(iid: 12, title: "PLUTO-231", sourceBranch: "feat/pluto-231", targetBranch: "main", author: "aiterm",
                                       state: "opened", draft: true, url: FakeMergeHost.url)
            $0.readiness = [.blocked(MergeReadiness.draftReason), .ready(head: ready.sha)]
        }
        #expect(await ready.finisher.finish(ready.task).draftNote == "MR !12 marked ready")

        // One that threads keep a draft is left one.
        let kept = try setUp(end: .merge)
        kept.host.update {
            $0.existing = MergeRequest(iid: 12, title: "PLUTO-231", sourceBranch: "feat/pluto-231", targetBranch: "main", author: "aiterm",
                                       state: "opened", draft: true, url: FakeMergeHost.url)
            $0.readiness = [.blocked(MergeReadiness.draftReason)]
            $0.threads = [ReviewThread(id: "d1", resolved: false, lastAuthor: "jan", lastBody: "Rename this")]
        }
        let blocked = await kept.finisher.finish(kept.task)
        #expect(blocked.result == .blocked && blocked.draftNote == "MR !12 left as a draft")
        #expect(kept.host.log.contains { $0.hasPrefix("ready") } == false)
    }

    /// The note comes from what the host says, never from the plan: a request found ready on a draft end is not a draft.
    @Test func aRequestFoundReadyIsNeverSaidToBeLeftAsADraft() async throws {
        let s = try setUp(end: .draftMR)
        s.host.update {
            $0.existing = MergeRequest(iid: 12, title: "PLUTO-231", sourceBranch: "feat/pluto-231", targetBranch: "main", author: "aiterm",
                                       state: "opened", draft: false, url: FakeMergeHost.url)
        }
        let result = await s.finisher.finish(s.task)
        #expect(result.result == .published && result.draftNote == nil)
        #expect(!s.host.log.contains { $0.hasPrefix("create") }, "the open request was adopted")
    }

    /// A call that failed after it marked the request ready still says so: the next call has nothing to say about it.
    @Test func aFailedCallSaysWhatItDidToTheDraftBeforeItFailed() async throws {
        let s = try setUp(end: .merge)
        s.host.update {
            $0.existing = MergeRequest(iid: 12, title: "PLUTO-231", sourceBranch: "feat/pluto-231", targetBranch: "main", author: "aiterm",
                                       state: "opened", draft: true, url: FakeMergeHost.url)
            $0.readiness = [.blocked(MergeReadiness.draftReason)]
            $0.readinessFailsAfterReady = true
        }
        let failed = await s.finisher.finish(s.task)
        #expect(failed.result == .failed && failed.draftNote == "MR !12 marked ready")
    }

    @Test func aGitHubRequestIsNumberedWithAHash() {
        #expect(TaskFinisher.draftNote(.opened(draft: true), request: "https://github.com/octocat/hello/pull/88", number: 88) == "MR #88 opened as a draft")
        #expect(TaskFinisher.draftNote(.markedReady, request: "https://git.example.net/web/acme-web/-/merge_requests/7", number: 7) == "MR !7 marked ready")
        #expect(TaskFinisher.draftNote(nil, request: FakeMergeHost.url, number: 12) == nil)
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
        #expect(first.result == .waitingToMerge)
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

    /// Only finish_task pushes (found in broadcast "Broadcast fix", 2026-11-05): a merge watch running on an open request
    /// whose task was accepted again on a fix-round commit pushes nothing. It stops, records why and tells the Operator,
    /// whose finish_task then pushes the commit and watches again.
    @Test func aMergeWatchNeverPushesANewlyAcceptedCommit() async throws {
        let s = try setUp(end: .merge)
        #expect(await s.finisher.finish(s.task).result == .waitingToMerge)
        try git.run(["commit", "--allow-empty", "-q", "-m", "fix round"], in: s.path)
        let fix = try git.run(["rev-parse", "HEAD"], in: s.path)
        s.store.mutate { $0.updateOperated(s.task) { $0.acceptance?.resultSHA = fix } }
        await s.ticker.tick()
        #expect(await eventually(describing: "the watch to stop") { s.finisher.watching.isEmpty })
        #expect(try git.run(["rev-parse", "feat/pluto-231"], in: s.origin) == s.sha, "nothing pushed")
        let why = TaskFinisher.unpushedAcceptance("PLUTO-231", sha: fix)
        #expect(why == "PLUTO-231’s accepted commit \(fix.prefix(7)) isn’t pushed: only finish_task pushes it.")
        #expect(s.stopped.all == [why])
        #expect(operated(s)?.publication?.problem == why)
        s.finisher.resumeWatching()
        #expect(s.finisher.watching.isEmpty, "it waits for finish_task")
        let pushed = await s.finisher.finish(s.task)
        #expect(pushed.pushedSHA == fix, "\(pushed)")
        #expect(try git.run(["rev-parse", "feat/pluto-231"], in: s.origin) == fix)
        #expect(s.finisher.watching == [s.task], "watched again")
    }

    /// A git that, once armed, holds the next read of the task branch's tip until the test lets it go.
    final class HeldTip: GitRunning, @unchecked Sendable {
        let inner = GitRunner.hermetic(), go = DispatchSemaphore(value: 0)
        private let state = Mutex((armed: false, holding: false))
        var holding: Bool { state.withLock { $0.holding } }
        func arm() { state.withLock { $0.armed = true } }
        func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
            let hold = args.first == "rev-parse" && args.contains("refs/heads/feat/pluto-231^{commit}")
                && state.withLock { s in defer { s.armed = false }; if s.armed { s.holding = true }; return s.armed }
            if hold { go.wait() }
            return try inner.run(args, in: dir, timeout: timeout, environment: environment)
        }
    }

    /// The same, accepted again while the watch's poll was reading git: what it hands the publisher is checked again, so
    /// the new commit is still never pushed by the watch.
    @Test func aMergeWatchNeverPushesACommitAcceptedWhileItsPollReadsGit() async throws {
        let held = HeldTip()
        let s = try setUp(end: .merge, git: held)
        defer { held.go.signal() }
        #expect(await s.finisher.finish(s.task).result == .waitingToMerge)
        held.arm()
        await s.ticker.tick()
        #expect(await eventually(describing: "the poll reading the branch's tip") { held.holding })
        try git.run(["commit", "--allow-empty", "-q", "-m", "fix round"], in: s.path)
        let fix = try git.run(["rev-parse", "HEAD"], in: s.path)
        s.store.mutate { $0.updateOperated(s.task) { $0.acceptance?.resultSHA = fix } }
        held.go.signal()
        #expect(await eventually(describing: "the watch to stop") { s.finisher.watching.isEmpty })
        #expect(try git.run(["rev-parse", "feat/pluto-231"], in: s.origin) == s.sha, "nothing pushed")
        #expect(s.stopped.all == [TaskFinisher.unpushedAcceptance("PLUTO-231", sha: fix)])
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
        s.finisher.disarm(s.task, because: TaskFinisher.takenOverProblem, kind: .failure)
        #expect(s.finisher.watching.isEmpty)
        #expect(operated(s)?.publication?.problem == TaskFinisher.takenOverProblem)
        s.store.mutate { $0.updateOperated(s.task) { $0.takenOver = false } }
        s.finisher.resumeWatching()
        #expect(s.finisher.watching.isEmpty)
        #expect(s.stopped.all.isEmpty && s.changed.ids.isEmpty, "you did it: no word to the operator from here")
        #expect(await s.finisher.finish(s.task).result == .waitingToMerge)
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
        #expect(again.result == .refused)
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
        #expect(a.result == .published)
        #expect(s.host.log.filter { $0.hasPrefix("create") }.count == 1)
        #expect(s.host.log.filter { $0.hasPrefix("protection") }.count == 1, "pushed once")
        #expect(s.finisher.running.isEmpty)
    }

    @Test func quittingDuringAHostWriteRecordsItsReplyWithoutStartingANewWatch() async throws {
        let s = try setUp(end: .merge)
        let gate = Ticker()
        s.host.update { $0.beforeCreate = { await gate.wait() } }
        let call = Task { await s.finisher.finish(s.task) }
        #expect(await eventually(describing: "the request to reach the host") { s.host.log.contains { $0.hasPrefix("create") } })
        s.finisher.stopAll()
        await gate.tick()
        _ = await call.value
        #expect(operated(s)?.publication?.mergeRequestNumber == 12, "an already completed write is still recorded")
        let saved = try s.store.file.load()
        #expect(saved.task(id: s.task)?.operated?.publication?.mergeRequestNumber == 12)
        #expect(s.finisher.watching.isEmpty)
        #expect(!s.host.log.contains { $0.hasPrefix("merge") })
    }

    /// The Operator's title, description and assignee that cannot be saved: nothing is pushed or opened, since a restart
    /// would open the request without them.
    @Test func contentThatCannotBeSavedPublishesNothing() async throws {
        let s = try setUp(end: .draftMR)
        #expect(s.store.flush(), "the workspace saves at first")
        try FileManager.default.createDirectory(at: s.store.file.backupURL, withIntermediateDirectories: true)
        let result = await s.finisher.finish(s.task, content: RequestContent(title: "PLUTO-231: Add gift card", assignee: "nathan"))
        #expect(result.result == .failed)
        #expect(result.reason == TaskFinisher.notSavedReason)
        #expect(s.host.log.isEmpty, "nothing asked of the host")
    }

    /// A merge watch's step saved after update_request reassigned the request while it awaited the host: the step's older
    /// copy neither brings back the assignment still to do nor the Operator's older choice.
    @Test func aStaleStepKeepsTheAssignmentUpdateRequestMade() {
        var stale = TaskPublication(mergeRequestNumber: 12)
        stale.requested = RequestContent(assignee: "nathan")
        stale.assigning = true
        stale.readySince = Date(timeIntervalSince1970: 1)
        var saved = TaskPublication(mergeRequestNumber: 12)
        saved.requested = RequestContent(assignee: "laurens")
        saved.assignee = "laurens"
        let kept = TaskFinisher.keepingNewerRequest(stale, over: saved)
        #expect(kept.requested?.assignee == "laurens")
        #expect(kept.assigning == nil && kept.assignee == "laurens")
        #expect(kept.readySince == stale.readySince, "the step's own progress is kept")
        // A request still to assign stays so: the step's own assignment is what records it.
        var pending = saved
        pending.assigning = true
        pending.assignee = nil
        var assigned = stale
        assigned.assigning = nil
        assigned.assignee = "laurens"
        #expect(TaskFinisher.keepingNewerRequest(assigned, over: pending).assignee == "laurens")
    }

    /// A step that cannot be saved is the last: no request is opened for a push the workspace does not know of.
    @Test func aStepThatCannotBeSavedStopsBeforeTheNext() async throws {
        let s = try setUp(end: .draftMR)
        #expect(s.store.flush(), "the workspace saves at first")
        try FileManager.default.createDirectory(at: s.store.file.backupURL, withIntermediateDirectories: true)
        let result = await s.finisher.finish(s.task)
        #expect(result.result == .failed)
        #expect(result.reason == TaskFinisher.notSavedReason)
        #expect(result.pushedSHA == s.sha, "it says the push it made")
        #expect(s.host.log == ["protection feat/pluto-231"], "pushed, then stopped")
        #expect(operated(s)?.state == .accepted)
    }

    /// A push that ran out of time may have landed: the answer never says nothing was pushed.
    @Test func aPushThatTimedOutMayHaveLanded() async throws {
        let s = try setUp(end: .draftMR, git: PushTimesOut())
        let result = await s.finisher.finish(s.task)
        #expect(result.result == .failed)
        #expect(result.reason == "The push of feat/pluto-231 timed out, so the push may have landed; call finish_task again, which asks origin before it pushes.")
        #expect(s.host.log == ["protection feat/pluto-231"])
        #expect(operated(s)?.publication?.pushedSHA == nil)
    }

    /// A pre-push hook that refuses: the answer says what the hook said, and the task records it, so
    /// its row says `blocked` rather than `opening the MR`. The next finish_task clears it and pushes.
    @Test func aPushTheHookRefusedIsRecordedInTheHooksWords() async throws {
        let s = try setUp(end: .draftMR)
        let hook = URL(fileURLWithPath: s.path).appendingPathComponent(".git/hooks/pre-push")
        try ("#!/bin/sh\necho 'lefthook: running pre-push' >&2\necho 'lint failed: src/a.ts' >&2\necho '  1:5  error  no-unused-vars' >&2\n"
            + "echo 'tsc: 2 errors' >&2\necho 'pre-push script failed' >&2\nexit 1\n")
            .write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let result = await s.finisher.finish(s.task)
        let why = "The pre-push hook refused the push of feat/pluto-231: lefthook: running pre-push\nlint failed: src/a.ts\n"
            + "  1:5  error  no-unused-vars\ntsc: 2 errors\npre-push script failed"
        #expect(result.result == .failed)
        #expect(s.forgotten.all.isEmpty, "ordinary hook failure keeps the login answers")
        #expect(result.reason == why)
        #expect(operated(s)?.publication?.problem == why)
        #expect(try StateStore(url: s.store.file.url).load().task(id: s.task)?.operated?.publication?.problem == why, "saved")
        let task = try #require(s.store.state.task(id: s.task)), run = try #require(s.store.state.run(id: s.run))
        #expect(OperatorLine.task(task, run: run, acting: nil, requests: [])?.look == .needsYou)

        try FileManager.default.removeItem(at: hook)
        let again = await s.finisher.finish(s.task)
        #expect(again.result == .published)
        #expect(operated(s)?.publication?.problem == nil)
    }

    // MARK: - What the card and run_status say comes from the current state (snag D)

    /// The task's line, its open requests and its run_status line, as the card and the Operator read them now.
    func shown(_ s: Setup) throws -> (line: OperatorLine?, requests: [BroadcastRequest], status: RunStatus.TaskLine) {
        let state = s.store.state
        let task = try #require(state.task(id: s.task)), run = try #require(state.run(id: s.run))
        let requests = OperatorRequests.open(run: run, state: state).filter { $0.taskId == s.task }
        let status = try #require(RunStatus.build(state: state, run: s.run, revision: 1, live: [:])?.tasks.first)
        return (OperatorLine.task(task, run: run, acting: nil, requests: requests), requests, status)
    }

    /// T1, challenge 7A68F0F0: a merge waiting on the host with the Oracle's yes for its evidence; mark_task refreshes the
    /// evidence on the same commit, which takes the yes away. The watch's next poll is refused for it. Nothing waits on the
    /// person: the merge waits for the Operator's next finish_task, which the Oracle judges. So the card doesn't say
    /// `blocked`, nobody is notified, and run_status says why the watch stopped.
    @Test func theOraclesYesToRenewWaitsOnTheOperatorNotOnYou() async throws {
        let s = try setUp(end: .merge, slices: Slices(merge: true))
        s.store.mutate { state in
            state.updateRun(id: s.run) { $0.profile.oracle.isOn = true }
            guard let task = state.task(id: s.task), let run = state.run(id: s.run) else { return }
            let evidence = PublicationGuard.evidence(task: task, run: run)
            state.updateOperated(s.task) {
                var publication = $0.publication ?? TaskPublication()
                publication.conditionsHeld = s.sha
                publication.conditionsEvidence = evidence
                $0.publication = publication
            }
        }
        #expect(await s.finisher.finish(s.task).result == .waitingToMerge)
        // mark_task accepted on the same commit with fresh evidence, as OperatorToolHandler+Tasks records it.
        s.store.mutate { state in
            state.updateOperated(s.task) {
                $0.acceptance?.checkOutput = "Head b30d82d: integration with main proven; gate green."
                $0.publication?.conditionsHeld = nil
            }
        }
        await s.ticker.tick()
        #expect(await eventually(describing: "the watch to stop") { s.finisher.watching.isEmpty })
        #expect(operated(s)?.publication?.problem == PublicationGuard.oracleYesNeeded)
        let now = try shown(s)
        #expect(now.line?.text == "accepted · waiting on the Operator" && now.line?.look == .quiet)
        #expect(now.requests.isEmpty, "nothing asks the person")
        #expect(now.status.publicationProblem == PublicationGuard.oracleYesNeeded, "run_status says what the card waits for")
        s.finisher.resumeWatching()
        #expect(s.finisher.watching.isEmpty, "held until the Operator's finish_task")

        // The Operator's next finish_task, the Oracle having said yes again, clears the hold and waits for the host.
        s.store.mutate { state in
            guard let task = state.task(id: s.task), let run = state.run(id: s.run) else { return }
            let evidence = PublicationGuard.evidence(task: task, run: run)
            state.updateOperated(s.task) { $0.publication?.conditionsHeld = s.sha; $0.publication?.conditionsEvidence = evidence }
        }
        #expect(await s.finisher.finish(s.task).result == .waitingToMerge)
        #expect(operated(s)?.publication?.problem == nil)
    }

    /// T7, 8eb4928 on !68: a merge end in review, accepted again for a fix round. The first push is refused by the pre-push
    /// hook, recorded as the task's problem; the next one lands and the task is back in review. The hook's label goes with
    /// the push that landed. Each push is the Operator's finish_task: a merge watch never pushes (broadcast "Broadcast
    /// fix", 2026-11-05), where 0.42.0's watch pushed these itself.
    @Test func aLaterPushThatLandsClearsTheHooksLabel() async throws {
        let s = try setUp(end: .merge, slices: Slices(review: true, merge: true))
        s.store.mutate { state in
            state.updateRun(id: s.run) { $0.taskSettings.review = "Assign Nathan, fix his feedback." }
            state.updateOperated(s.task) {
                $0.publication = TaskPublication(pushedSHA: "e5c1d0a2b7f4c9e3d8a1b6f0c2e4d7a9b3c5e8f1", mergeRequestURL: FakeMergeHost.url,
                                                 mergeRequestNumber: 12, targetBranch: "main", repository: FakeMergeHost.repository)
                $0.peopleReview = PeopleReview(reviewers: ["nathan.geleyn"], startedAt: Date(timeIntervalSince1970: 0))
            }
        }
        let hook = try writeHook("#!/bin/sh\necho 'lefthook: running pre-push'\necho 'sh: npm: command not found' >&2\nexit 1\n", in: s)
        #expect(await s.finisher.finish(s.task).result == .failed)
        #expect(operated(s)?.publication?.problem?.hasPrefix("The pre-push hook refused the push of feat/pluto-231") == true)
        #expect(try shown(s).line?.look == .needsYou, "while the refusal holds, the task looks blocked")

        try FileManager.default.removeItem(at: hook)
        _ = await s.finisher.finish(s.task)
        #expect(operated(s)?.state == .inReview)
        #expect(try git.run(["rev-parse", "refs/heads/feat/pluto-231"], in: s.origin) == s.sha)
        #expect(operated(s)?.publication?.problem == nil)
        let now = try shown(s)
        #expect(now.line?.text == "in review · waiting on nathan.geleyn" && now.line?.look == .quiet)
        #expect(now.requests.isEmpty && now.status.publicationProblem == nil)
    }

    /// A merge end in review whose open request already holds an earlier push, accepted again on a fix commit, with the
    /// Oracle on: what `UpstreamReplacement.reaccept` leaves before the Operator's next finish_task pushes it.
    func reacceptedInReview(_ s: Setup) {
        s.store.mutate { state in
            state.updateRun(id: s.run) {
                $0.taskSettings.review = "Assign Nathan, fix his feedback."
                $0.profile.oracle.isOn = true
            }
            state.updateOperated(s.task) {
                $0.publication = TaskPublication(pushedSHA: "e5c1d0a2b7f4c9e3d8a1b6f0c2e4d7a9b3c5e8f1", mergeRequestURL: FakeMergeHost.url,
                                                 mergeRequestNumber: 12, targetBranch: "main", repository: FakeMergeHost.repository)
                $0.peopleReview = PeopleReview(reviewers: ["nathan.geleyn"], startedAt: Date(timeIntervalSince1970: 0))
            }
        }
    }

    /// FE Sprint 84, fe-1801 on !75: accepted again on a fix commit, the task was watched as a merge waiting (mark_task's
    /// `runChanged` resumes watches); finish_task pushed it back into review, and the watch's next poll ended that review,
    /// stopped on the Oracle's hold and said so, while the request still waited on its reviewer. Its next publication enters
    /// review, so nothing watches it, and the review goes on.
    @Test func aTaskAcceptedAgainWhileInReviewIsNotWatchedAndStaysInReview() async throws {
        let s = try setUp(end: .merge, slices: Slices(review: true, merge: true))
        reacceptedInReview(s)
        s.finisher.resumeWatching()
        #expect(s.finisher.watching.isEmpty, "its next finish_task pushes it into review, not to a merge")
        let pushed = await s.finisher.finish(s.task)
        #expect(pushed.result == .inReview)
        #expect(try git.run(["rev-parse", "refs/heads/feat/pluto-231"], in: s.origin) == s.sha)
        s.finisher.resumeWatching()
        await s.ticker.tick()
        #expect(s.finisher.watching.isEmpty)
        #expect(operated(s)?.state == .inReview && operated(s)?.peopleReview?.ended != true)
        #expect(operated(s)?.publication?.problem == nil && s.stopped.all.isEmpty)
    }

    /// Only the Operator's finish_task ends a review. A watch's poll that finds its task in review (a watch armed before it
    /// went there) changes nothing, ends, and wakes nobody: the review watcher speaks for the review.
    @Test func aMergeWatchsPollNeverEndsAReview() async throws {
        let s = try setUp(end: .merge, slices: Slices(review: true, merge: true))
        s.host.update { $0.readiness = [.waiting("its pipeline is running")] }
        #expect(await s.finisher.finish(s.task).result == .waitingToMerge)
        #expect(s.finisher.watching == [s.task])
        s.store.mutate { state in
            state.updateRun(id: s.run) { $0.taskSettings.review = "Assign Nathan, fix his feedback." }
            state.updateOperated(s.task) {
                $0.state = .inReview
                $0.peopleReview = PeopleReview(reviewers: ["nathan.geleyn"], startedAt: Date(timeIntervalSince1970: 0))
            }
        }
        await s.ticker.tick()
        #expect(await eventually(describing: "the watch to end") { s.finisher.watching.isEmpty })
        #expect(operated(s)?.state == .inReview && operated(s)?.peopleReview?.ended != true)
        #expect(operated(s)?.publication?.problem == nil)
        #expect(s.stopped.all.isEmpty && s.changed.ids.isEmpty)
    }

    /// A host read that failed once during a merge wait, then answers it waits: the failure's problem goes. A hold set while
    /// a poll is in flight (your change of end to Merge) is kept.
    @Test func aWaitThatGoesOnClearsAFailureButKeepsAHold() async throws {
        let s = try setUp(end: .merge)
        #expect(await s.finisher.finish(s.task).result == .waitingToMerge)
        s.host.update { $0.readinessFailures = 1 }
        await s.ticker.tick()
        #expect(await eventually(describing: "the failed read recorded") { operated(s)?.publication?.problem != nil })
        await s.ticker.tick()
        #expect(await eventually(describing: "the failure cleared") { operated(s)?.publication?.problem == nil })
        #expect(s.finisher.watching == [s.task])

        let release = AsyncStream<Void>.makeStream()
        s.host.update { $0.beforeReadiness = { for await _ in release.stream { break } } }
        let reads = s.host.log.filter { $0.hasPrefix("readiness") }.count
        await s.ticker.tick()
        #expect(await eventually(describing: "a poll in flight") { s.host.log.filter { $0.hasPrefix("readiness") }.count > reads })
        s.finisher.disarm(s.task, because: TaskEndChange.mergeWaitsForFinish, kind: .hold)
        release.continuation.finish()
        #expect(await eventually(describing: "the poll to end") { !s.finisher.running.contains(s.task) })
        #expect(operated(s)?.publication?.problem == TaskEndChange.mergeWaitsForFinish)
        #expect(s.finisher.watching.isEmpty)
    }

    func writeHook(_ script: String, in s: Setup) throws -> URL {
        let hook = URL(fileURLWithPath: s.path).appendingPathComponent(".git/hooks/pre-push")
        try script.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        return hook
    }

    /// noVerify skips a hook only once a push without it showed what the hook says (spec §B): the refused push's
    /// output is kept on the task for the Oracle, and the push past the hook clears it.
    @Test func noVerifyNeedsAFailedPushFirst() async throws {
        let s = try setUp(end: .draftMR)
        let first = await s.finisher.finish(s.task, noVerify: true)
        #expect(first.result == .refused && first.reason == "Push without noVerify first, so the hook's output is known.")
        #expect(s.host.log.isEmpty, "nothing asked, nothing pushed")

        _ = try writeHook("#!/bin/sh\necho 'lefthook: running pre-push'\necho 'sh: npm: command not found' >&2\nexit 1\n", in: s)
        #expect(await s.finisher.finish(s.task).result == .failed)
        #expect(operated(s)?.publication?.lastPushFailure == "lefthook: running pre-push\nsh: npm: command not found")
        #expect(operated(s)?.publication?.lastPushFailureSHA == s.sha, "the commit the hook refused")
        #expect(try StateStore(url: s.store.file.url).load().task(id: s.task)?.operated?.publication?.lastPushFailure != nil, "saved")

        let past = await s.finisher.finish(s.task, noVerify: true)
        #expect(past.result == .published && past.pushedSHA == s.sha)
        #expect(try git.run(["rev-parse", "refs/heads/feat/pluto-231"], in: s.origin) == s.sha)
        #expect(operated(s)?.publication?.lastPushFailure == nil, "a push that landed leaves no failure to judge")
        // Asked again, its reply lost: what was done, not a refusal. (The note says what a call did to the draft: this one did nothing.)
        #expect(await s.finisher.finish(s.task, noVerify: true) == past.withoutDraftNote)
    }

    /// The hook's refusal holds for the commit it refused: one accepted since must be pushed without noVerify first.
    @Test func aRefusalOfAnotherCommitIsNoReasonToSkipTheHook() async throws {
        let s = try setUp(end: .draftMR)
        let hook = try writeHook("#!/bin/sh\necho 'sh: npm: command not found' >&2\nexit 1\n", in: s)
        #expect(await s.finisher.finish(s.task).result == .failed)
        try git.run(["commit", "--allow-empty", "-q", "-m", "the fix"], in: s.path)
        let head = try git.run(["rev-parse", "HEAD"], in: s.path)
        s.store.mutate { $0.updateOperated(s.task) { $0.acceptance?.resultSHA = head } }
        let refused = await s.finisher.finish(s.task, noVerify: true)
        #expect(refused.result == .refused && refused.reason == "Push without noVerify first, so the hook's output is known.")
        #expect(try Repository(s.path, git: git).originTip(of: "feat/pluto-231") == nil)
        try FileManager.default.removeItem(at: hook)
    }

    /// A hook that could not find its tool was run with a PATH that has since changed (an install, a
    /// new nvm default), so the login shell is asked again before the next push.
    @Test func commandNotFoundReadsThePathAgain() async throws {
        let s = try setUp(end: .draftMR)
        _ = try writeHook("#!/bin/sh\necho 'fakenpm: command not found' >&2\nexit 1\n", in: s)
        let result = await s.finisher.finish(s.task)
        #expect(result.result == .failed)
        #expect(result.reason?.contains("fakenpm: command not found") == true)
        #expect(s.forgotten.all.count == 1)
    }

    @Test func aHostThatIsNotConnectedIsRefusedBeforeAnythingIsPushed() async throws {
        let s = try setUp(end: .draftMR, connect: { _ in throw MergeRequestSearch.Unavailable.notConnected(.gitLab) })
        let result = await s.finisher.finish(s.task)
        #expect(result == TaskFinisher.Result(result: .refused, reason: "acme-web has no connected code host.",
                                              mergeRequest: nil, pushedSHA: nil, merged: false, mergedSHA: nil))
        #expect((try? git.run(["rev-parse", "--verify", "--quiet", "refs/heads/feat/pluto-231"], in: s.origin)) == nil)
    }

    /// What the plan rules out is said as such, before any host is connected.
    @Test func aCommitEndIsRefusedWithoutAHost() async throws {
        let s = try setUp(end: .commit, connect: { _ in throw MergeRequestSearch.Unavailable.notConnected(.gitLab) })
        let result = await s.finisher.finish(s.task)
        #expect(result.result == .refused)
        #expect(result.reason == "PLUTO-231 ends in a commit: its plan opens no merge request, so there is nothing to finish.")
        #expect(s.remotes.all.isEmpty)
    }

    @Test func aStoppedOperationStaysUnpublishedAcrossARestart() async throws {
        let s = try setUp(end: .merge)
        s.store.mutate { state in state.runs[0].state = .stopped }
        let result = await s.finisher.finish(s.task)
        #expect(result.result == .refused)
        #expect(result.reason == "The broadcast was stopped; it publishes nothing.")
        s.finisher.resumeWatching()
        #expect(s.finisher.watching.isEmpty)
    }

    /// Merged on the host with a head nobody accepted: a question for you, never watched or retried.
    @Test func aForeignMergeIsPutToYouAndNotWatched() async throws {
        let s = try setUp(end: .merge)
        s.host.update { $0.readiness = [.merged(commit: "f00df00d", head: "0123456789abcdef")] }
        let result = await s.finisher.finish(s.task)
        #expect(result.result == .blocked)
        #expect(result.mergedSHA == "f00df00d" && !result.merged)
        #expect(result.reason == "PLUTO-231 was merged on the host at 0123456, not the accepted \(s.sha.prefix(7)): it holds commits that weren't accepted.")
        #expect(s.mergedOnHost.all == [s.task])
        #expect(s.finisher.watching.isEmpty)
        s.finisher.resumeWatching()
        #expect(s.finisher.watching.isEmpty)
        let again = await s.finisher.finish(s.task)
        #expect(again == result.withoutDraftNote, "a repeat answers what happened")
        #expect(!s.host.log.contains { $0.hasPrefix("merge") })
    }

    // MARK: - The Merge slice and the local merge (spec §5)

    /// With the Merge slice off a merge end is refused before anything is pushed, and left for you once.
    @Test func aMergeWithTheSliceOffIsLeftForYou() async throws {
        let s = try setUp(end: .merge, slices: .none)
        let result = await s.finisher.finish(s.task)
        #expect(result.result == .refused && result.reason == "The Merge slice is off for this broadcast.")
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
        #expect(result == TaskFinisher.Result(result: .published, reason: nil, mergeRequest: nil, pushedSHA: nil, merged: true, mergedSHA: main))
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

    /// Origin out of reach (found in broadcast "Broadcast fix", 2026-11-05): a local merge pushes nothing, so it goes
    /// ahead, reading origin as last fetched, and its answer says origin couldn't be read.
    @Test func aLocalMergeGoesAheadWhenOriginCantBeFetched() async throws {
        let s = try setUp(end: .mergeLocal)
        try git.run(["switch", "-q", "main"], in: s.path)
        try git.run(["remote", "set-url", "origin", s.path + "-gone"], in: s.path)
        let result = await s.finisher.finish(s.task)
        #expect(result.result == .published && result.merged, "\(result)")
        #expect(result.reason?.hasPrefix("Merged locally. AiTerm couldn’t fetch main from origin") == true, "\(String(describing: result.reason))")
        #expect(try git.run(["rev-parse", "main^2"], in: s.path) == s.sha)
        #expect(operated(s)?.state == .published)
    }

    /// A checkout with uncommitted changes is refused, and nothing is left for you to push.
    @Test func aLocalMergeIntoADirtyCheckoutIsRefused() async throws {
        let s = try setUp(end: .mergeLocal)
        try git.run(["switch", "-q", "main"], in: s.path)
        try "x".write(toFile: s.path + "/notes.txt", atomically: true, encoding: .utf8)
        try git.run(["add", "notes.txt"], in: s.path)
        let result = await s.finisher.finish(s.task)
        #expect(result.result == .refused)
        #expect(result.reason == LocalMerge.Refusal.uncommittedChanges(s.path).localizedDescription)
        #expect(operated(s)?.state == .accepted)
        #expect(s.store.state.run(id: s.run)?.leftForYou.isEmpty == true)
    }

    // MARK: - Work that reached its target outside finish_task

    /// The Oracle on, as when it refused the merge: a commit already in main is recorded without its yes.
    func oracleOn(_ s: Setup) {
        s.store.mutate { $0.updateRun(id: s.run) { $0.profile.oracle.isOn = true } }
    }

    /// The accepted commit merged into the checkout's main by hand, as a worker or the person does, with a merge commit;
    /// `push` pushes main to origin as well. The checkout is back on the task's branch after.
    func mergeByHand(_ s: Setup, push: Bool = false) throws {
        try git.run(["switch", "-q", "main"], in: s.path)
        try git.run(["merge", "-q", "--no-ff", "--no-edit", s.sha], in: s.path)
        if push { try git.run(["push", "-q", "origin", "main"], in: s.path) }
        try git.run(["switch", "-q", "feat/pluto-231"], in: s.path)
    }

    /// Merged into local main by a worker (t-runtime-progress): recorded as merged at once, with no Oracle asked, nothing
    /// pushed and nothing written to the host, even with the branch moved on since; pushing main is left for you.
    @Test func workMergedIntoLocalMainOutsideFinishTaskIsRecordedAsMerged() async throws {
        let s = try setUp(end: .merge)
        oracleOn(s)
        try mergeByHand(s)
        try git.run(["commit", "--allow-empty", "-q", "-m", "after the merge"], in: s.path)
        s.store.mutate { $0.updateOperated(s.task) {
            $0.publication = TaskPublication(problem: "the pipeline failed", mergeRefusal: "The Oracle judged that the conditions to merge don’t hold yet: no review.")
        } }
        let result = await s.finisher.finish(s.task)
        #expect(result.result == .published && result.merged && result.mergedSHA == nil, "no merge commit is made up from ancestry")
        #expect(result.reason?.contains("already in main") == true, "\(result.reason ?? "")")
        let publication = try #require(operated(s)?.publication)
        #expect(operated(s)?.state == .published)
        #expect(publication.merged && publication.landedSHA == s.sha && publication.targetBranch == "main")
        #expect(publication.problem == nil && publication.mergeRefusal == nil)
        #expect(s.host.log == ["existing feat/pluto-231"], "the host is only read")
        #expect(try git.run(["for-each-ref", "refs/heads/feat/pluto-231"], in: s.origin).isEmpty, "nothing pushed")
        #expect(s.store.state.run(id: s.run)?.leftForYou == ["Push main in acme-web: PLUTO-231's commit is in it locally, not in origin/main as last fetched."])
        let saved = try StateStore(url: s.store.file.url).load()
        #expect(saved.task(id: s.task)?.operated?.publication?.landedSHA == s.sha, "on disk")
        #expect(await s.finisher.finish(s.task) == TaskFinisher.Result(publication, result: .published, reason: nil), "a repeat is answered from the record")
        #expect(s.store.state.run(id: s.run)?.leftForYou.count == 1)
    }

    /// Merged into main on origin as well: nothing is left to push.
    @Test func workAlreadyOnOriginsMainLeavesNothingToPush() async throws {
        let s = try setUp(end: .merge)
        oracleOn(s)
        try mergeByHand(s, push: true)
        let result = await s.finisher.finish(s.task)
        #expect(result.result == .published && result.merged)
        #expect(operated(s)?.publication?.landedSHA == s.sha)
        #expect(s.store.state.run(id: s.run)?.leftForYou.isEmpty == true)
        #expect(!s.host.log.contains { !$0.hasPrefix("existing") }, "\(s.host.log)")
    }

    /// Its request still open on the host: closing it is left for you, and AiTerm writes nothing to it.
    @Test func anOpenRequestOfWorkAlreadyMergedIsLeftForYouToClose() async throws {
        let s = try setUp(end: .merge)
        oracleOn(s)
        try mergeByHand(s, push: true)
        s.host.update {
            $0.existing = MergeRequest(iid: 12, title: "PLUTO-231", sourceBranch: "feat/pluto-231", targetBranch: "main", author: "aiterm",
                                       state: "opened", draft: false, url: FakeMergeHost.url)
        }
        let result = await s.finisher.finish(s.task)
        #expect(result.result == .published && result.merged)
        #expect(s.store.state.run(id: s.run)?.leftForYou == ["Close MR !12 in acme-web without merging: its commit is already in main."])
        #expect(s.host.log == ["existing feat/pluto-231"])
    }

    /// Only the commit accepted now counts: another one in main, a task taken over, or nothing merged, and finish_task goes
    /// on as before, the Oracle's yes needed for its merge.
    @Test func onlyTheAcceptedCommitInMainIsRecordedAsMerged() async throws {
        let s = try setUp(end: .merge)
        oracleOn(s)
        let oracleReason = "The Oracle hasn’t said that the task’s review conditions hold for PLUTO-231, so AiTerm doesn’t merge it: call finish_task again."
        let unmerged = await s.finisher.finish(s.task)
        #expect(unmerged.result == .refused && unmerged.reason == oracleReason, "nothing in main: as before")

        try mergeByHand(s, push: true)
        s.store.mutate { $0.updateOperated(s.task) { $0.takenOver = true } }
        let taken = await s.finisher.finish(s.task)
        #expect(taken.result == .refused && taken.reason == "You've taken PLUTO-231 over; it is published only once you hand it back.")
        s.store.mutate { $0.updateOperated(s.task) { $0.takenOver = false } }

        // Accepted again on a fix that isn't in main.
        try git.run(["commit", "--allow-empty", "-q", "-m", "the fix"], in: s.path)
        let fix = try git.run(["rev-parse", "HEAD"], in: s.path)
        s.store.mutate { $0.updateOperated(s.task) { $0.acceptance?.resultSHA = fix } }
        let refused = await s.finisher.finish(s.task)
        #expect(refused.result == .refused && refused.reason == oracleReason)
        #expect(operated(s)?.state == .accepted && operated(s)?.publication?.merged != true && operated(s)?.publication?.landedSHA == nil)
        #expect(s.host.log.isEmpty && s.store.state.run(id: s.run)?.leftForYou.isEmpty == true)
    }

    /// A merge left for you with the Merge slice off, then merged by the person: finish_task records it as merged.
    @Test func workLeftForYouAndMergedByHandIsRecordedAsMerged() async throws {
        let s = try setUp(end: .merge, slices: .none)
        #expect(await s.finisher.finish(s.task).result == .refused)
        #expect(await s.finisher.finish(s.task).result == .leftForYou)
        try mergeByHand(s, push: true)
        let result = await s.finisher.finish(s.task)
        #expect(result.result == .published && result.merged)
        #expect(operated(s)?.state == .published && operated(s)?.publication?.leftForYou == false)
    }
}

extension TaskFinisher.Result {
    /// What it answered, less what that call did to the request's draft state: a repeat of a call did nothing to it.
    var withoutDraftNote: Self { var copy = self; copy.draftNote = nil; return copy }
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
            ports.clock.overrideSleep(.merge) { _ in await ticker.wait() }
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
            ports.clock.overrideSleep(.merge) { duration in await ticker.wait(); clock.slept(duration / .seconds(1)) }
            ports.clock.now = { clock.now }
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
        await world.settled()
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
        await world.settled()
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
        #expect(first.result == .refused)
        #expect(operated(s)?.publication?.leftForYou == true)
        #expect(RunScheduler.isComplete(s.store.state.run(id: s.run)!, in: s.store.state))
        #expect(await s.finisher.finish(s.task).result == .leftForYou)
        #expect(s.store.state.run(id: s.run)?.leftForYou.count == 1)
    }

    /// A protection lookup that failed can succeed on the next call: the task stays AiTerm's to publish.
    @Test func aFailedProtectionLookupIsNotLeftForYou() async throws {
        let s = try setUp(end: .draftMR)
        s.host.update { $0.protectionFails = true }
        #expect(await s.finisher.finish(s.task).result == .refused)
        #expect(operated(s)?.publication?.leftForYou != true)
        #expect(s.store.state.run(id: s.run)?.leftForYou.isEmpty == true)
        #expect(!RunScheduler.isComplete(s.store.state.run(id: s.run)!, in: s.store.state))
    }

    @Test func aProjectWithNoOriginSettlesAsLeftForYou() async throws {
        let s = try setUp(end: .draftMR)
        _ = try git.run(["remote", "remove", "origin"], in: s.path)
        #expect(await s.finisher.finish(s.task).result == .refused)
        #expect(operated(s)?.publication?.leftForYou == true)
        #expect(s.store.state.run(id: s.run)?.leftForYou.first?.contains("feat/pluto-231") == true)
        #expect(RunScheduler.isComplete(s.store.state.run(id: s.run)!, in: s.store.state))
    }
}


extension TaskFinisherTests {
    @Test func anOldSteeringReleaseCannotReleaseARestoredTasksNewHold() async throws {
        let s = try setUp(end: .draftMR)
        let task = try #require(s.store.state.task(id: s.task))
        let oldRelease = s.finisher.hold(s.task)
        s.store.mutate { $0.tasks.removeAll { $0.id == s.task } }
        s.finisher.forgetRemovedTasks()
        s.store.mutate { $0.tasks.append(task) }
        let newRelease = s.finisher.hold(s.task)
        oldRelease()
        let held = await s.finisher.finish(s.task)
        #expect(held.result == .refused && held.reason == TaskFinisher.beingSteered("PLUTO-231"))
        newRelease()
        let finished = await s.finisher.finish(s.task)
        #expect(finished.result == .published)
    }

    /// Main 51f83d77's complete result shape, before internal refusal kinds were carried.
    private struct CurrentFinishResult: Codable {
        let result: TaskFinisher.Result.Kind
        let reason: String?, mergeRequest: String?, pushedSHA: String?
        let merged: Bool
        let mergedSHA: String?, draftNote: String?
    }

    @Test func internalOutcomeKindsKeepTheCurrentResultBytes() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let cases: [(String?, TaskPublication.ProblemKind?)] = [
            (nil, nil), ("The branch moved.", .failure), (PublicationGuard.mergeSliceOff, .permanent),
            (PublicationGuard.oracleYesNeeded, .hold), ("A host says no connected code host here.", .permanent),
            ("The branch is the default branch, as a host diagnostic.", .permanent),
        ]
        for (reason, kind) in cases {
            let actual = TaskFinisher.Result(result: .refused, reason: reason, mergeRequest: FakeMergeHost.url,
                                             pushedSHA: "accepted", merged: true, mergedSHA: "merged", draftNote: "left as a draft")
            let current = CurrentFinishResult(result: actual.result, reason: actual.reason, mergeRequest: actual.mergeRequest,
                                              pushedSHA: actual.pushedSHA, merged: actual.merged, mergedSHA: actual.mergedSHA,
                                              draftNote: actual.draftNote)
            #expect(actual.problemKind == kind)
            #expect(try encoder.encode(actual) == encoder.encode(current))
            #expect(try JSONDecoder().decode(TaskFinisher.Result.self, from: encoder.encode(current)) == actual)
        }
    }
}


extension TaskFinisherTests {
    @Test func removingATaskDuringAHostWriteKeepsItsCallWithinItsBudget() async throws {
        let work = OperatorWork(), creating = OracleGate(), entered = Recorded<String>()
        let s = try setUp(end: .draftMR, work: work)
        s.host.update { script in
            script.beforeCreate = { entered.append("creating"); await creating.wait() }
        }
        var answer: TaskFinisher.Result?
        work.start { _ = await s.finisher.finish(s.task) }
        await eventually(describing: "creation entered after the push") { entered.all == ["creating"] }
        work.start { answer = await s.finisher.finish(s.task, budget: .milliseconds(400)) }
        await eventually(describing: "the budgeted caller joined the held publication") { s.finisher.joined == 1 }
        s.store.mutate { $0.tasks.removeAll { $0.id == s.task } }
        s.finisher.forgetRemovedTasks()
        // The sent creation and its unbudgeted starter remain. The joined tool caller still answers on time.
        await work.settled(leaving: 2)
        #expect(answer?.result == .running)
        #expect(s.finisher.running.isEmpty && !s.finisher.pending(s.task))
        await creating.open()
        await work.settled()
        #expect(s.finisher.running.isEmpty && s.finisher.watching.isEmpty && !s.finisher.pending(s.task))
        #expect(s.store.state.task(id: s.task) == nil)
    }
}
