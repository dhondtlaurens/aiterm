import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Work budgets for the Operator (plan 2026-11-10, phase 0): what one step costs today in `run_status` builds, worker
/// turn reads, git processes and code-host requests, counted by `WorkMeter` or a recording fake, never timed. Each
/// number is exact and is today's: a later change that makes the step cheaper lowers it here, and none may raise it.
@MainActor @Suite(.blocking) struct OperatorWorkBudgetTests {
    // MARK: - The frozen broadcast, as the contract journey builds it

    /// The frozen broadcast's tabs as `OperatorCurrentContractTests.journey` lists them: each task's worker in a window
    /// of its own, the working task's at work and every other done, and each extra tab beside it, Codex and done.
    static func frozenSessions(_ state: AppState) throws -> [SessionInfo] {
        let working = try #require(state.tasks.first { $0.operated?.state == .working })
        return state.tasks.enumerated().flatMap { index, task -> [SessionInfo] in
            var first = OperatorServiceFixtures.session("main-\(index)", window: "window-\(index)", tag: task.id,
                                                        state: task.id == working.id ? .working : .done,
                                                        conversation: "conversation-\(index)", cwd: task.worktreePath)
            first.tabIndex = 0
            let extras = (task.operated?.extraTabs ?? []).enumerated().map { place, tab -> SessionInfo in
                var session = OperatorServiceFixtures.session(tab.sessionId ?? "extra-\(index)-\(place)", window: first.windowId,
                                                              tag: task.id, agent: .codex, state: .done,
                                                              conversation: tab.conversation, cwd: task.worktreePath)
                session.tabKey = tab.key
                session.tabIndex = place + 1
                return session
            }
            return [first] + extras
        }
    }

    /// The frozen broadcast's world, built as the journey builds it: its clock held, an Oracle that agrees, the tabs
    /// assigned to the live sessions.
    @MainActor struct Frozen {
        let world: OperatorWorld, run: UUID, working: TaskItem, sessions: [SessionInfo]

        init() throws {
            let state = try OperatorCurrentContractTests.load(), epoch = OperatorCurrentContractTests.epoch
            world = try OperatorWorld(state) { ports in
                ports.clock.now = { epoch }
                ports.secondOpinion = .answering("YES\nThe recorded result meets the goal.")
            }
            run = try #require(state.runs.first?.id)
            working = try #require(state.tasks.first { $0.operated?.state == .working })
            sessions = try OperatorWorkBudgetTests.frozenSessions(state)
            world.live.sessions = sessions
        }

        /// The working task's worker tab.
        var worker: SessionInfo { sessions.first { $0.taskUUID == working.id && $0.tabIndex == 0 }! }

        /// A session event as the app routes it: the live sessions take it, then the Operator.
        func deliver(_ session: SessionInfo) {
            world.live.handle(.sessionChanged(session))
            world.controller.handle(.sessionChanged(session))
        }

        func call(_ name: String, _ arguments: JSONValue = [:]) async throws -> JSONValue {
            let run = try #require(world.run(self.run))
            return try await world.controller.tools.perform(ToolCall(tool: name, arguments: arguments), in: run)
        }

        /// The steady state a step is counted from: iTerm2's tabs listed in a connected snapshot, one reconcile tick and
        /// one session event behind it, and everything they started finished.
        func primed() async {
            world.show(sessions)
            await Budget.settle(world.controller)
            world.controller.reconcileTick()
            await Budget.settle(world.controller)
            var event = worker
            event.contextPercent = 39
            deliver(event)
            await Budget.settle(world.controller)
        }
    }

    // MARK: - `run_status` builds per step

    /// One `session.changed` for the working worker that moves only its context fill, with what it starts let finish:
    /// 1 `RunStatus.build`, the session handling's look at the open run for the waker and the watchdog (`observeRuns`);
    /// and no worker turn read: the three done workers and six done extra tabs are asked about again, but none of their
    /// transcripts was written since it was last read (`TranscriptLocator.reply`), so neither a transcript's tail nor git
    /// is read. Phase 0 counted 9 reads, one for each, read again though none of them changed. None may raise either.
    @Test func aSessionEventBuildsTheStatus() async throws {
        let frozen = try Frozen()
        defer { frozen.world.controller.stop() }
        await frozen.primed()
        var event = frozen.worker
        event.contextPercent = 40

        let work = await Budget.metered {
            frozen.deliver(event)
            await Budget.settle(frozen.world.controller)
        }

        #expect(work[.statusBuild] == 1, "status builds per session event: \(work)")
        #expect(work[.turnRead, default: 0] == 0, "turn reads per session event: \(work)")
    }

    /// One reconcile tick of the frozen broadcast, its tabs known, with what it starts let finish: 1 `RunStatus.build`,
    /// the tick's one snapshot for the waker, the watchdog and the quiet check (`observeRuns`); and 9 worker turn reads,
    /// the three done workers' and six done extra tabs' transcripts read in full, whatever their stamps say: the tick is
    /// where a change no stat can see is read (`TranscriptLocator`). Phase 0 counted 2 builds, the quiet check
    /// (`checkQuiet`) building the same status again, and 9 reads. None may raise either.
    @Test func aReconcileTickBuildsTheStatus() async throws {
        let frozen = try Frozen()
        defer { frozen.world.controller.stop() }
        await frozen.primed()

        let work = await Budget.metered {
            frozen.world.controller.reconcileTick()
            await Budget.settle(frozen.world.controller)
        }

        #expect(work[.statusBuild] == 1, "status builds per reconcile tick: \(work)")
        #expect(work[.turnRead] == 9, "turn reads per reconcile tick: \(work)")
    }

    /// A reconcile tick a reconcile interval after the last, with one task's worker idle, its turn ended and read, and a
    /// sibling task at work whose time the tick counts, which changes the workspace before the tick reads the ended turns:
    /// 1 worker turn read, the idle worker's transcript read in full once, not lost to the read that change started
    /// (phase 5, review round 2). The frozen broadcast's tick (above) counts no time, its clock held.
    @Test func aReconcileTickWithABusySiblingReadsTheIdleTurnInFullOnce() async throws {
        let clock = TestClock.operators()
        let fixture = WorkerTurnReaderTests()
        let (world, run, task, _) = try fixture.makeWorld(worker: .idle, clock: clock)
        defer { world.controller.stop() }
        let project = try #require(world.state.projects.first)
        var busy = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-2", state: .working, worktree: "/tmp/aiterm-wt-busy")
        busy.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now.addingTimeInterval(-3600),
                                              openedAt: clock.now.addingTimeInterval(-3600))
        world.workspace.mutate { $0.tasks.append(busy) }
        world.show(fixture.sessions(run, task, .idle) + [OperatorServiceFixtures.session("w2", window: "w10", tag: busy.id, state: .working,
                                                                                          conversation: "conv-busy")])
        try BranchWatchTests().saveReply("Wired it.", conversation: "conv-1", in: world)
        world.controller.reconcileTick()
        await Budget.settle(world.controller)
        let counted = world.task(busy.id)?.operated?.totalRuntimeUsed ?? 0
        clock.advance(by: OperatorTiming.reconcileInterval)

        let work = await Budget.metered {
            world.controller.reconcileTick()
            await Budget.settle(world.controller)
        }

        #expect((world.task(busy.id)?.operated?.totalRuntimeUsed ?? 0) > counted, "the sibling's time counted")
        #expect(work[.turnRead] == 1, "turn reads per reconcile tick with a busy sibling: \(work)")
    }

    /// One mutating tool call, `ask_you` about the working task as the journey asks it, with what it starts let finish:
    /// 3 `RunStatus.build`s, the handler's look before and after the call to tell whether it changed what `run_status`
    /// shows, and the waker's look at the changed workspace. A later change that builds the status once per call lowers
    /// it; none may raise it.
    @Test func aMutatingToolCallBuildsTheStatus() async throws {
        let frozen = try Frozen()
        defer { frozen.world.controller.stop() }
        await frozen.primed()
        let key = try #require(frozen.working.operated?.key)

        let work = try await Budget.metered {
            _ = try await frozen.call("ask_you", ["key": "finish-copy", "question": "May the task finish without a code change?",
                                                  "task": .string(key)])
            await Budget.settle(frozen.world.controller)
        }

        #expect(frozen.world.run(frozen.run)?.questions.contains { $0.id == "finish-copy" } == true, "asked")
        #expect(work[.statusBuild] == 3, "status builds per mutating tool call: \(work)")
    }

    /// The whole frozen contract journey (`OperatorCurrentContractTests.journey`): its tool calls, its pauses, its goal
    /// rounds, its restart. 47 `RunStatus.build`s: twelve `run_status` answers and the handler's, the waker's and the
    /// watchdog's looks around every change. A later change that builds less lowers it; none may raise it.
    ///
    /// Saves by the caller (`StateStore.save`, as a flush does) are at most 1, and not exact: the journey's one
    /// `flush()` writes only when the debounced background save (not counted, off the caller's task) has not written
    /// that revision yet, which is a race against its 200 ms delay; runs counted 0 and 1. The worker turn reads also
    /// vary (72 to 76), with how many reads are still in flight when the next change comes, and are not asserted.
    @Test func theFrozenJourneyBuildsAndSaves() async throws {
        let state = try OperatorCurrentContractTests.load()
        let work = try await Budget.metered { _ = try await OperatorCurrentContractTests.journey(state) }
        #expect(work[.statusBuild] == 47, "status builds across the journey: \(work)")
        #expect(work[.stateSave, default: 0] <= 1, "saves across the journey: \(work)")
    }

    // MARK: - Worker turn reads

    /// One task working in its own worktree, its worker idle at its prompt with its turn ended and read, its reply in its
    /// transcript, as `WorkerTurnReaderTests` builds it. Five workspace changes that touch no task (the sidebar's frame), each let
    /// finish: no turn read, its transcript not written since it was read. Five session events for its tab that move
    /// only its context fill: none either. Phase 0 counted 5 and 5, one read per change though nothing about the worker
    /// changed. None may raise them. Its transcript written again, with a new reply, the next session event reads it: 1.
    @Test func anIdleWorkersEndedTurnIsReadOnlyOnceItsTranscriptChanged() async throws {
        let (world, _, task, _) = try WorkerTurnReaderTests().makeWorld(worker: .idle)
        defer { world.controller.stop() }
        try BranchWatchTests().saveReply("Wired it.", conversation: "conv-1", in: world)
        world.controller.turns.observe()
        await Budget.settle(world.controller)
        #expect(world.controller.turns.readings[task.id]?.lastMessage == "Wired it.", "its turn is read")

        let changes = await Budget.metered {
            for n in 1...5 {
                world.workspace.mutate { $0.sidebarFrame = CGRect(x: n, y: 0, width: 300, height: 800) }
                await Budget.settle(world.controller)
            }
        }
        var tab = try #require(world.live.sessions.first { $0.taskUUID == task.id })
        let events = await Budget.metered {
            for n in 1...5 {
                tab.contextPercent = n * 10
                world.live.handle(.sessionChanged(tab))
                world.controller.handle(.sessionChanged(tab))
                await Budget.settle(world.controller)
            }
        }

        try BranchWatchTests().saveReply("Wired it, and tested it.", conversation: "conv-1", in: world)
        let written = await Budget.metered {
            tab.contextPercent = 70
            world.live.handle(.sessionChanged(tab))
            world.controller.handle(.sessionChanged(tab))
            await Budget.settle(world.controller)
        }

        #expect(changes[.turnRead, default: 0] == 0, "turn reads per 5 no-op workspace changes: \(changes)")
        #expect(events[.turnRead, default: 0] == 0, "turn reads per 5 session events: \(events)")
        #expect(written[.turnRead] == 1, "turn reads once its transcript changed: \(written)")
        #expect(world.controller.turns.readings[task.id]?.lastMessage == "Wired it, and tested it.")
    }

    // MARK: - Git per BranchWatch pass

    /// One task working in its own worktree, its worker idle with a last message that names one commit, made on another
    /// branch, as `BranchWatchTests` builds it; its turn read first. Then the reconcile tick's branch pass
    /// (`BranchWatch.poll`), twice, each with what it starts let finish, as git sees it.
    ///
    /// First pass: 9 spawns. 7 look up the one commit the message names (`rev-parse --verify`, `merge-base
    /// --is-ancestor`, `for-each-ref --contains`, `reflog show`, `cherry`, the default branch's `for-each-ref` and
    /// `rev-parse --verify`), 1 reads the head and its branch (`rev-parse HEAD --symbolic-full-name HEAD`) and 1 the refs
    /// (`for-each-ref`). Second, nothing changed: 2, the head and the refs, the message's lookup kept for its words, the
    /// head and the refs (phase 0 counted 9, the head read in two and the commit looked up again). None may raise either.
    @Test func aBranchWatchPassSpawnsGit() async throws {
        let git = RecordingGitRunner(forwardingTo: GitRunner.hermetic())
        let fixture = BranchWatchTests()
        let (world, _, task, worktree) = try fixture.makeWorld(worker: .idle, conversation: "conv-1", adjust: { $0.git = git })
        defer { world.controller.stop() }
        let elsewhere = try GitFixture.folder("op-drift-tmp-") + "/other"
        try fixture.git.run(["worktree", "add", "-q", "-b", "feat/my-own", elsewhere], in: worktree)
        try fixture.git.run(["commit", "--allow-empty", "-q", "-m", "the fix"], in: elsewhere)
        let sha = try fixture.git.run(["rev-parse", "HEAD"], in: elsewhere)
        try fixture.saveReply("Done. Committed \(sha) on feat/my-own; all 41 tests pass.", conversation: "conv-1", in: world)
        world.controller.turns.observe()
        await Budget.settle(world.controller)

        func pass() async -> [String] {
            let mark = git.calls.count
            world.controller.branchWatch.poll()
            await Budget.settle(world.controller)
            return Budget.commands(git, since: mark)
        }
        let first = await pass(), second = await pass()

        #expect(world.task(task.id)?.operated?.branchDrift?.sha == sha, "the drift is found")
        #expect(first.count == 9, "spawns on the first pass: \(first)")
        #expect(second.count == 2, "spawns on a pass that finds nothing new: \(second)")
    }

    // MARK: - Host requests

    /// The `OperatorReviewTests` broadcast with `count` tasks in review, each with its draft request open (!12, !13, …)
    /// and people's review begun, all on one repository whose origin the fake host is bound to; git recorded.
    func inReview(_ count: Int, git: RecordingGitRunner) async throws -> OperatorReviewTests.Reviewed {
        let reviewed = try await OperatorReviewTests().reviewed(.inReview, adjust: { $0.git = git })
        reviewed.world.workspace.mutate { state in
            for n in 1..<count {
                var task = reviewed.task
                task.id = UUID()
                task.title = "Task A\(n)"
                task.operated?.key = "A\(n)"
                task.operated?.publication?.mergeRequestNumber = 12 + n
                state.tasks.append(task)
            }
        }
        await Budget.settle(reviewed.world.controller)
        return reviewed
    }

    /// One `ReviewWatcher` pass, as the reconcile tick starts it, over `count` tasks in review on one repository, let
    /// finish: per task, 2 logged host requests (`threads`, `approvals`); per pass, 1 unlogged lookup of the token's user
    /// and 1 `git remote get-url` to find the host, the project's host found once. Phase 0 counted the lookup and the
    /// origin read once per task: 1 and 5 each. None may raise these numbers.
    @Test(arguments: [1, 5]) func aReviewWatcherPassAsksTheHost(count: Int) async throws {
        let git = RecordingGitRunner(forwardingTo: GitRunner.hermetic())
        let r = try await inReview(count, git: git)
        defer { r.world.controller.stop() }
        let logged = r.host.log.count, users = r.host.userLookups, mark = git.calls.count

        r.world.controller.reviewWatcher.poll()
        await Budget.settle(r.world.controller)

        let requests = Array(r.host.log.dropFirst(logged)), spawned = Budget.commands(git, since: mark)
        #expect(requests.count == 2 * count, "host requests per pass over \(count): \(requests)")
        #expect(r.host.userLookups - users == 1, "user lookups per pass over \(count)")
        #expect(spawned.filter { $0 == "remote get-url" }.count == 1, "origin reads per pass over \(count): \(spawned)")
    }

    /// One `run_status` call over `count` tasks in people's review, the host's readings not kept yet, let finish: per
    /// task, 2 host requests (its threads, read on every call, and its request's state, kept for `hostCache`) and 2
    /// `git remote get-url` to find the host, one for each. A second call at once: the threads again, the state kept,
    /// so 1 request and 1 origin read per task. A later change that finds the host once per call lowers the origin
    /// reads; none may raise any of these.
    @Test(arguments: [1, 5, 20]) func aRunStatusCallAsksTheHost(count: Int) async throws {
        let git = RecordingGitRunner(forwardingTo: GitRunner.hermetic())
        let r = try await inReview(count, git: git)
        defer { r.world.controller.stop() }

        func call() async -> (requests: [String], origins: Int) {
            let logged = r.host.log.count, mark = git.calls.count
            let answer = await r.world.call(r.run.id, "run_status")
            #expect(answer.value?["tasks"]?.arrayValue?.count == count)
            await Budget.settle(r.world.controller)
            return (Array(r.host.log.dropFirst(logged)), Budget.commands(git, since: mark).filter { $0 == "remote get-url" }.count)
        }
        let cold = await call(), warm = await call()

        #expect(cold.requests.count == 2 * count, "host requests per cold run_status over \(count): \(cold.requests)")
        #expect(cold.origins == 2 * count, "origin reads per cold run_status over \(count)")
        #expect(warm.requests.count == count, "host requests per warm run_status over \(count): \(warm.requests)")
        #expect(warm.origins == count, "origin reads per warm run_status over \(count)")
    }
}


extension OperatorWorkBudgetTests {
    /// Baseline for phase 6's settings synchronization: one redundant profile read on an ordinary tool call.
    @Test func aToolCallReadsOracleSettings() async throws {
        let (world, run, _) = try OperatorServiceFixtures.oneWorkingTask()
        defer { world.controller.stop() }
        let work = try await Budget.metered {
            #expect(await world.call(run.id, "ask_you", ["key": "q", "question": "Which locale?"]).message == nil)
            await world.ports.work.settled()
        }
        #expect(work[.oracleSettingsRead] == 1)
    }

    /// Baseline: the gate fetches for landing, then the finisher fetches for the same landing again.
    @Test func aJudgedMergeFetchesItsLandingCheck() async throws {
        let git = RecordingGitRunner(forwardingTo: GitRunner.hermetic())
        let m = try OperatorMergeTests().merging(answer: "YES") { $0.git = git }
        defer { m.world.controller.stop() }
        let mark = git.calls.count
        let answer = await m.world.call(m.run.id, "finish_task", ["task": "A"])
        #expect(answer.value?["result"] == "waitingToMerge")
        await m.world.ports.work.settled()
        let fetches = git.calls.dropFirst(mark).filter { $0.args.contains("fetch") }.map(\.args)
        #expect(fetches.count == 2, "landing-check fetches in a judged merge: \(fetches)")
    }
}
