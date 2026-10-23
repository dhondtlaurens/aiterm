import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Reconciliation (spec §7.3, §8, §11): hints are never trusted alone; every minute and on every
/// reconnect AiTerm looks at the real tabs and says what it finds.
@MainActor @Suite(.blocking) struct RunReconcilerTests {
    let clock = TestClock.operators()

    func makeWorld(_ state: AppState, daemon: RecordingDaemon = RecordingDaemon()) throws -> OperatorWorld {
        try OperatorWorld(state, daemon: daemon) { [clock] ports in ports.now = { clock.now } }
    }

    @Test func anOperatorsTabGoneTakesItsBroadcastOfflineAndItsReturnBringsItBackButNeverUnpauses() throws {
        let project = OperatorServiceFixtures.project()
        let active = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var paused = OperatorServiceFixtures.run(projects: [project], state: .paused)
        paused.intent = .paused
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [active, paused]))
        world.show([])
        world.controller.reconcileTick()
        #expect(world.run(active.id)?.state == .operatorOffline)
        #expect(world.run(paused.id)?.state == .paused)
        world.show([OperatorServiceFixtures.session("op", tag: active.id), OperatorServiceFixtures.session("op2", window: "w2", tag: paused.id)])
        world.controller.reconcileTick()
        #expect(world.run(active.id)?.state == .active)
        #expect(world.run(paused.id)?.state == .paused)
    }

    /// Spec §13: a conversation that can't be resumed is said, and nothing opens; Start Fresh then opens a new
    /// Operator session, its conversation let go, briefed with where the broadcast stands and its decisions.
    @Test func startFreshWhenTheConversationCannotResume() async throws {
        let project = OperatorServiceFixtures.project()
        var run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        run.operatorConversation = "c-gone"
        run.decisions = [OperatorDecision(key: "d1", text: "Ship the footer fix first.", task: nil, at: clock.now)]
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .working, worktree: "/tmp/aiterm-wt")
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        world.show([OperatorServiceFixtures.session("op", tag: run.id, conversation: "c-gone")])
        world.show([])
        #expect(world.run(run.id)?.state == .operatorOffline)
        let refusal = await #expect(throws: ActionUnavailable.self) { try await world.controller.resume(run: run.id) }
        #expect(refusal?.message == "Its conversation can’t be resumed.")
        #expect(world.daemon.requests("window.createTask").isEmpty && world.run(run.id)?.state == .operatorOffline)
        try await world.controller.startFresh(run: run.id)
        let folder = OperatorCommand.runFolder(run.id, home: world.ports.home)
        let command = try String(contentsOf: folder.appendingPathComponent(OperatorCommand.launchFile), encoding: .utf8)
        #expect(command.contains(OperatorCommand.firstMessageFile) && !command.contains("c-gone"))
        let first = try String(contentsOf: folder.appendingPathComponent(OperatorCommand.firstMessageFile), encoding: .utf8)
        #expect(first.hasPrefix("Your broadcast:\n\nImplement the sprint."))
        #expect(first.contains("\"key\":\"PLUTO-1\""), "where it stands, as run_status shows it")
        #expect(first.contains("Ship the footer fix first."), "the decisions so far")
        #expect(!first.contains("—"))
        #expect(world.run(run.id)?.operatorConversation == nil && world.run(run.id)?.state == .active)
    }

    @Test func aLaunchThatShowedNoTabIsTriedAgainOnlyAfterAMinute() async throws {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-reconcile-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .working)
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now)
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        world.controller.reconcileTick()
        await world.controller.reconciler.lastLaunch?.value
        #expect(world.daemon.requests("window.createTask").isEmpty)
        clock.advance(by: 61)
        world.controller.reconcileTick()
        await world.controller.reconciler.lastLaunch?.value
        #expect(world.daemon.requests("window.createTask").first?.params["background"] as? Bool == true)
        #expect(world.task(task.id)?.operated?.launch?.number == 2)
        #expect(try world.workspace.file.load().task(id: task.id)?.operated?.launch?.number == 2)
    }

    /// A worker whose window showed and was then closed is neither launched again nor reopened by the
    /// tick: it comes back on your click (`reopenWorker`, D16), never as a second worker.
    @Test func aWorkerWhoseWindowYouClosedIsLeftForYourClick() async throws {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-closed-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: .working, worktree: project.path)
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now)
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        let op = OperatorServiceFixtures.session("op", tag: run.id)
        world.show([op, OperatorServiceFixtures.session("w1", window: "w9", tag: task.id)])
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.launch?.openedAt == clock.now, "its tab was seen: the launch showed a window")
        world.workspace.mutate { state in
            if let i = state.tasks.firstIndex(where: { $0.id == task.id }) { state.tasks[i].windowId = nil }
        }
        world.show([op])
        clock.advance(by: 120)
        world.controller.reconcileTick()
        await world.controller.reconciler.lastLaunch?.value
        #expect(world.daemon.requests("window.createTask").isEmpty)
        #expect(world.task(task.id)?.operated?.launch?.number == 1)
    }

    /// Spec §8: a worker past its runtime is blocked and you are asked. Only its time at work counts —
    /// not time waiting on you, nor the time AiTerm was not running — and what is counted is saved.
    @Test func aWorkerPastItsRuntimeIsBlockedCountingOnlyItsTimeAtWork() async throws {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-5", state: .working, worktree: "/tmp/aiterm-wt")
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now, openedAt: clock.now)
        task.operated?.runtimeUsed = 89 * 60
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        let tabs = [OperatorServiceFixtures.session("op", tag: run.id),
                    OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, state: .working)]
        world.show(tabs)
        world.controller.reconcileTick()   // the first tick after AiTerm starts only sets the clock
        world.workspace.mutate { $0.updateOperated(task.id) { $0.flags.insert(.waitingOnYou) } }
        clock.advance(by: 50)
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.runtimeUsed == 89 * 60.0, "time waiting on you is not work")
        world.workspace.mutate { $0.updateOperated(task.id) { $0.flags.remove(.waitingOnYou) } }
        clock.advance(by: 30)
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.runtimeUsed == 89 * 60 + 30.0)
        #expect(world.workspace.flush())
        // AiTerm quits for an hour and starts again: what was counted is kept, the hour is not counted.
        clock.advance(by: 3600)
        let restarted = try makeWorld(try world.workspace.file.load())
        restarted.show(tabs)
        restarted.controller.reconcileTick()
        #expect(restarted.task(task.id)?.operated?.runtimeUsed == 89 * 60 + 30.0)
        clock.advance(by: 31)
        restarted.controller.reconcileTick()
        let blocked = try #require(restarted.task(task.id)?.operated)
        #expect(blocked.state == .blocked && blocked.blockedReason == "Worked its 90 minutes without finishing.")
        #expect(restarted.notifications.posted.last?.target == .board(run.id))
    }

    /// Each working task on its own clock: the quiet one is flagged and its Operator told once across ticks, a busy
    /// sibling is not, and the quiet one's next sign clears it.
    @Test func aWorkerWorkingWithNoChangeForTwentyMinutesIsPossiblyStalledUntilItChanges() async throws {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-2", state: .working, worktree: "/tmp/aiterm-wt")
        var busy = OperatorServiceFixtures.task(in: run, project: project, key: "BUSY-1", state: .working, worktree: "/tmp/aiterm-wt-busy")
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now)
        busy.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now)
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task, busy]))
        var worker = OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, state: .working)
        var sibling = OperatorServiceFixtures.session("w2", window: "w8", tag: busy.id, state: .working)
        worker.title = "thinking"
        sibling.title = "reading"
        func show() { world.show([OperatorServiceFixtures.session("op", tag: run.id), worker, sibling]) }
        func stalledLines() -> [String] {
            world.daemon.requests("session.deliver").compactMap { $0.params["text"] as? String }.filter { $0.contains("stalled") }
        }
        show()
        world.controller.reconcileTick()
        clock.advance(by: 15 * 60)
        sibling.title = "editing"
        show()
        clock.advance(by: 6 * 60)
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.flags.contains(.possiblyStalled) == true)
        #expect(world.task(busy.id)?.operated?.flags.contains(.possiblyStalled) == false)
        try await world.daemon.received("session.deliver")
        #expect(world.daemon.requests("session.deliver").last?.params["text"] as? String == "[AiTerm] one task may be stalled, call run_status")
        world.controller.reconcileTick()
        // A second line would be armed with no coalescing delay and typed within a few turns of the main actor.
        for _ in 0..<50 { await Task.yield() }
        await world.controller.waker.lastSend?.value
        #expect(stalledLines().count == 1, "told once")
        worker.title = "editing"
        show()
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.flags.contains(.possiblyStalled) == false)
    }

    @Test func reconnectingSetsEachTasksOwnershipAgain() async throws {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-3", state: .working, worktree: "/tmp/aiterm-wt")
        task.operated?.ownership = 3
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        world.controller.daemonAttached()
        world.show([OperatorServiceFixtures.session("op", tag: run.id), OperatorServiceFixtures.session("w1", window: "w9", tag: task.id)])
        await world.controller.resending?.value
        let sent = try #require(world.daemon.requests("session.setOwnership").first)
        #expect(sent.params["sessionId"] as? String == "w1" && sent.params["ownership"] as? Int == 3)
    }

    @Test func aWorkersPromptIsAQuestionWaitingOnYouUntilItLeavesThePrompt() async throws {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-4", state: .working, agent: .codex, worktree: "/tmp/aiterm-wt")
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        world.daemon.prompts["w1"] = .permission
        world.show([OperatorServiceFixtures.session("op", tag: run.id), OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, agent: .codex, state: .needsInput)])
        await world.controller.lastProbe?.value
        let question = try #require(world.run(run.id)?.questions.last)
        #expect(question.text == "Codex asks for permission" && question.task == task.id && question.resolution == nil)
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == true)
        #expect(world.notifications.posted.last?.target == .task(task.id))
        #expect(world.notifications.posted.last?.body == "Codex asks for permission in Task PLUTO-4.")
        #expect(world.notifications.withdrawn.isEmpty)
        world.show([OperatorServiceFixtures.session("op", tag: run.id), OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, agent: .codex, state: .working)])
        #expect(world.run(run.id)?.questions.last?.resolution == "Answered in its window.")
        #expect(world.notifications.withdrawn == ["request-\(run.id.uuidString)-\(task.id.uuidString)-permission"], "answered in its window, it is taken back")
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == false)
    }

    /// Spec §7.1: AiTerm declines Codex's update offer itself, with Esc — the daemon sends it only when
    /// the screen shows that dialog — and a trust question stays yours.
    @Test func aCodexUpdateOfferIsDeclinedByAiTermAndATrustQuestionGoesToYou() async throws {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active)
        let update = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-6", state: .working, agent: .codex, worktree: "/tmp/aiterm-wt")
        let trust = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-7", state: .working, agent: .codex, worktree: "/tmp/aiterm-wt2")
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [update, trust]))
        world.daemon.prompts = ["w1": .startup, "w2": .startup]
        world.daemon.dismissible = ["w1"]
        let op = OperatorServiceFixtures.session("op", tag: run.id)
        world.show([op, OperatorServiceFixtures.session("w1", window: "w9", tag: update.id, agent: .codex, state: .needsInput)])
        await world.controller.lastProbe?.value
        #expect(world.daemon.requests("session.dismissStartup").map { $0.params["sessionId"] as? String } == ["w1"])
        #expect(world.run(run.id)?.questions.isEmpty == true && world.notifications.posted.isEmpty)
        world.show([op, OperatorServiceFixtures.session("w1", window: "w9", tag: update.id, agent: .codex, state: .working),
                    OperatorServiceFixtures.session("w2", window: "w8", tag: trust.id, agent: .codex, state: .needsInput)])
        await world.controller.lastProbe?.value
        let question = try #require(world.run(run.id)?.questions.last)
        #expect(question.text == "Codex shows a startup question" && question.task == trust.id)
        #expect(world.notifications.posted.last?.target == .task(trust.id))
    }

    // -- decisions taken after review ---------------------------------------------------------

    /// A tab tagged with the task is its worker, whatever the launch record says: adopted, and never
    /// launched again once it is closed.
    @Test func aLiveTabTaggedWithTheTaskIsAdoptedAndNeverLaunchedAgain() async throws {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-adopt-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-8", state: .working)
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now)
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        let op = OperatorServiceFixtures.session("op", tag: run.id)
        world.show([op, OperatorServiceFixtures.session("w1", window: "w9", tag: task.id)])
        clock.advance(by: 120)
        world.controller.reconcileTick()
        world.show([op])
        world.workspace.mutate { state in
            if let i = state.tasks.firstIndex(where: { $0.id == task.id }) { state.tasks[i].windowId = nil }
        }
        clock.advance(by: 120)
        world.controller.reconcileTick()
        await world.controller.reconciler.lastLaunch?.value
        #expect(world.task(task.id)?.operated?.launch?.openedAt != nil)
        #expect(world.daemon.requests("window.createTask").isEmpty)
    }

    /// D10 blocks a retry whose worker is still busy before its launch showed a window: the tab that is
    /// there is adopted while the task is blocked, and resuming it never launches a second worker.
    @Test func aBlockedTasksLiveWorkerIsAdoptedSoResumingItNeverLaunchesASecond() async throws {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-busy-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-9", state: .blocked, worktree: project.path)
        task.operated?.blockedFrom = .working
        task.operated?.blockedReason = "AiTerm couldn’t start it: its worker is still busy; stop it or wait."
        task.operated?.retriesUsed = 1
        task.operated?.launch = LaunchAttempt(number: 2, requestedAt: clock.now)
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        let op = OperatorServiceFixtures.session("op", tag: run.id)
        world.show([op, OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, state: .working)])
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.launch?.openedAt == clock.now)
        world.workspace.mutate { state in
            state.updateOperated(task.id) { $0.state = .working; $0.blockedReason = nil; $0.blockedFrom = nil }
        }
        world.show([op])
        clock.advance(by: 300)
        world.controller.reconcileTick()
        await world.controller.reconciler.lastLaunch?.value
        #expect(world.daemon.requests("window.createTask").isEmpty)
    }

    /// A reply lost to a timeout can leave the window it asked for: a relaunch looks for it by its tag
    /// at the last moment and adopts it instead of opening a second.
    @Test func aRelaunchFindsAnOrphanWindowByItsTagBeforeOpeningAnother() async throws {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-orphan-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-10", state: .working)
        let attempt = LaunchAttempt(number: 2, requestedAt: clock.now)
        task.operated?.launch = attempt
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        world.show([OperatorServiceFixtures.session("op", tag: run.id), OperatorServiceFixtures.session("w1", window: "w9", tag: task.id)])
        await world.controller.starter.relaunch(task.id, attempt: attempt)?.value
        #expect(world.daemon.requests("window.createTask").isEmpty)
        let adopted = try #require(world.task(task.id))
        #expect(adopted.windowId == "w9" && adopted.operated?.launch?.openedAt != nil)
    }

    /// A resumed broadcast, and a helper that attached again, start what was waiting: the tick
    /// triggers the scheduler as the tool paths do.
    @Test func aResumedRunAndAReattachedHelperStartWhatWasWaiting() async throws {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-resume-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .operatorOffline, planRevision: 1)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-11", state: .queued)
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        world.controller.reconcileTick()
        #expect(world.run(run.id)?.state == .active)
        await world.controller.lastStart?.value
        #expect(world.daemon.requests("window.createTask").count == 1)
        #expect(world.task(task.id)?.operated?.state == .working)
        // A queued task whose start was held back for want of a helper starts on the first connected snapshot.
        let later = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-12", state: .queued)
        world.workspace.mutate { $0.tasks.append(later) }
        world.workspace.mutate { $0.updateOperated(task.id) { $0.state = .accepted; $0.acceptance = TaskAcceptance(resultSHA: "abc", prerequisiteSHAs: [], checkOutput: "ok", note: nil, at: Date()) } }
        world.link.attached = false
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        world.controller.reconcileTick()
        #expect(world.task(later.id)?.operated?.state == .queued, "no helper to open its window")
        world.link.attached = true
        world.controller.daemonAttached()
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        await world.controller.lastStart?.value
        #expect(world.task(later.id)?.operated?.state == .working)
    }

    /// A task that failed with no retry left is blocked and you are asked, as a task past its runtime is.
    @Test func aFailedTaskWithNoRetriesLeftIsBlockedAndYouAreAsked() throws {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-13", state: .failed, worktree: "/tmp/aiterm-wt")
        task.operated?.retriesUsed = OperatorTiming.retries
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        world.controller.reconcileTick()
        let blocked = try #require(world.task(task.id)?.operated)
        #expect(blocked.state == .blocked && blocked.blockedReason == "Failed with no retries left (2 allowed).")
        #expect(world.notifications.posted.last?.target == .board(run.id))
    }

    /// A paused run's workers are not working time.
    @Test func aPausedRunsWorkersCountNoRuntime() throws {
        let project = OperatorServiceFixtures.project()
        var run = OperatorServiceFixtures.run(projects: [project], state: .paused, planRevision: 1)
        run.intent = .paused
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-14", state: .working, worktree: "/tmp/aiterm-wt")
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now, openedAt: clock.now)
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        world.show([OperatorServiceFixtures.session("op", tag: run.id), OperatorServiceFixtures.session("w1", window: "w9", tag: task.id)])
        world.controller.reconcileTick()
        clock.advance(by: 50)
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.runtimeUsed == 0)
    }

    /// A prompt question left open on a task that has ended would keep its broadcast from completing:
    /// its tab leaving the prompt resolves it, and the run then settles.
    @Test func resolvingTheLastPromptOfAnEndedTaskCompletesItsBroadcast() async throws {
        let project = OperatorServiceFixtures.project()
        var run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-16", state: .accepted, worktree: "/tmp/aiterm-wt")
        task.operated?.acceptance = TaskAcceptance(resultSHA: "abc", prerequisiteSHAs: [], checkOutput: "ok", note: nil, at: Date())
        run.questions = [OperatorQuestion(id: "prompt-\(task.id.uuidString)-1", text: "Codex asks for permission", task: task.id, askedAt: clock.now)]
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        world.show([OperatorServiceFixtures.session("op", tag: run.id), OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, state: .working)])
        #expect(world.run(run.id)?.questions.last?.resolution == "Answered in its window.")
        #expect(world.run(run.id)?.state == .complete)
    }

    // -- fix round 1 --------------------------------------------------------------------------

    /// Spec §8: you resolve a runtime block by resuming, and the task gets a fresh allowance — left with the
    /// time it used, the next pass would block it again. A block for another reason keeps its runtime.
    @Test func aTaskBlockedForItsRuntimeIsResumedWithAFreshAllowanceAndOneBlockedForAnotherReasonKeepsItsTime() throws {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var spent = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-20", state: .working, worktree: "/tmp/aiterm-wt")
        spent.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now, openedAt: clock.now)
        spent.operated?.runtimeUsed = 90 * 60
        var partway = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-21", state: .working, worktree: "/tmp/aiterm-wt2")
        partway.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now, openedAt: clock.now)
        partway.operated?.runtimeUsed = 30 * 60
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [spent, partway]))
        world.show([OperatorServiceFixtures.session("op", tag: run.id),
                    OperatorServiceFixtures.session("w1", window: "w9", tag: spent.id, state: .working),
                    OperatorServiceFixtures.session("w2", window: "w8", tag: partway.id, state: .working)])
        world.controller.reconcileTick()
        #expect(world.task(spent.id)?.operated?.state == .blocked && world.task(spent.id)?.operated?.runtimeUsed == 90 * 60)
        world.workspace.mutate { state in
            _ = try? OperatedTransitions.apply(.block(reason: "needs a key"), toTask: partway.id, in: &state, by: .operatorTool)
            _ = try? OperatedTransitions.apply(.resume, toTask: spent.id, in: &state, by: .operatorTool)
            _ = try? OperatedTransitions.apply(.resume, toTask: partway.id, in: &state, by: .operatorTool)
        }
        clock.advance(by: 30)
        world.controller.reconcileTick()
        let resumed = try #require(world.task(spent.id)?.operated)
        #expect(resumed.state == .working && resumed.runtimeUsed == 30, "a fresh 90 minutes, counted from its resume")
        let kept = try #require(world.task(partway.id)?.operated)
        #expect(kept.state == .working && kept.runtimeUsed == 30 * 60 + 30)
    }

    /// Only a busy worker's time counts: one idle at its prompt, its turn over, waits for review or acceptance, and
    /// is never blocked for its runtime, even one already past it. Once it works again the limit holds.
    @Test func anIdleWorkerCountsNoRuntimeAndIsNeverBlockedWhileItWaitsForAcceptance() throws {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var fresh = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-23", state: .working, worktree: "/tmp/aiterm-wt")
        fresh.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now, openedAt: clock.now)
        fresh.operated?.runtimeUsed = 10 * 60
        var spent = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-24", state: .working, worktree: "/tmp/aiterm-wt2")
        spent.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now, openedAt: clock.now)
        spent.operated?.runtimeUsed = 95 * 60
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [fresh, spent]))
        world.show([OperatorServiceFixtures.session("op", tag: run.id),
                    OperatorServiceFixtures.session("w1", window: "w9", tag: fresh.id, state: .idle),
                    OperatorServiceFixtures.session("w2", window: "w8", tag: spent.id, state: .done)])
        world.controller.reconcileTick()
        clock.advance(by: 50)
        world.controller.reconcileTick()
        #expect(world.task(fresh.id)?.operated?.runtimeUsed == 10 * 60.0, "an idle worker is not at work")
        let waiting = try #require(world.task(spent.id)?.operated)
        #expect(waiting.state == .working && waiting.runtimeUsed == 95 * 60.0, "finished work waits for acceptance, unblocked")
        // It is told to fix something and works again: past its limit, it is blocked.
        world.show([OperatorServiceFixtures.session("op", tag: run.id),
                    OperatorServiceFixtures.session("w1", window: "w9", tag: fresh.id, state: .working),
                    OperatorServiceFixtures.session("w2", window: "w8", tag: spent.id, state: .working)])
        clock.advance(by: 30)
        world.controller.reconcileTick()
        #expect(world.task(fresh.id)?.operated?.runtimeUsed == 10 * 60 + 30.0)
        #expect(world.task(spent.id)?.operated?.state == .blocked)
    }

    /// Only time with a worker at work counts: a task with no tab (its window closed, a relaunch pending) uses none.
    @Test func aWorkingTaskWithNoWorkerTabCountsNoRuntime() throws {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-22", state: .working, worktree: "/tmp/aiterm-wt")
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now, openedAt: clock.now)
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        world.controller.reconcileTick()
        clock.advance(by: 50)
        world.controller.reconcileTick()
        #expect(world.task(task.id)?.operated?.runtimeUsed == 0)
    }

    /// A request that timed out may still open its window: the minute before the reconciler launches again
    /// is counted from when the launch ended, not from its claim, which came before the worktree and the request.
    @Test func aWindowRequestThatTimedOutIsGivenAMinuteFromWhenItEndedBeforeAnotherLaunch() async throws {
        let daemon = RecordingDaemon(holding: "window.createTask")
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-timeout-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-23", state: .queued)
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), daemon: daemon)
        let op = OperatorServiceFixtures.session("op", tag: run.id)
        world.show([op])
        world.controller.startReadyTasks()
        try await daemon.received("window.createTask")
        clock.advance(by: 90)   // the claim is old by the time the request times out
        daemon.failing["window.createTask"] = .timeout
        daemon.release()
        await world.controller.lastStart?.value
        #expect(world.task(task.id)?.operated?.launch?.openedAt == nil)
        world.controller.reconcileTick()
        await world.controller.reconciler.lastLaunch?.value
        #expect(daemon.requests("window.createTask").count == 1, "its window may still be listed: a minute from the end, not the claim")
        clock.advance(by: 61)
        daemon.failing = [:]
        world.controller.reconcileTick()
        await world.controller.reconciler.lastLaunch?.value
        #expect(daemon.requests("window.createTask").count == 2)
        #expect(world.task(task.id)?.operated?.launch?.number == 2)
    }

    /// With no end of its launch known — AiTerm started after it — the minute is counted from the first pass
    /// that saw the tabs, so a window iTerm2 was slow to list is found first.
    @Test func aLaunchFromBeforeAiTermStartedWaitsAMinuteFromTheFirstPass() async throws {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-restart-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-24", state: .working)
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now.addingTimeInterval(-3600))
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        world.controller.reconcileTick()
        await world.controller.reconciler.lastLaunch?.value
        #expect(world.daemon.requests("window.createTask").isEmpty)
        clock.advance(by: 61)
        world.controller.reconcileTick()
        await world.controller.reconciler.lastLaunch?.value
        #expect(world.daemon.requests("window.createTask").count == 1)
    }

    /// Two passes while a relaunch is still asking for its window make one request, not two.
    @Test func twoTicksWhileARelaunchIsHeldMakeOneWindowRequest() async throws {
        let daemon = RecordingDaemon(holding: "window.createTask")
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-overlap-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-25", state: .working)
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now)
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), daemon: daemon)
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        world.controller.reconcileTick()
        clock.advance(by: 61)
        world.controller.reconcileTick()
        try await daemon.received("window.createTask")
        clock.advance(by: 120)
        world.controller.reconcileTick()
        world.controller.reconcileTick()
        #expect(daemon.requests("window.createTask").count == 1)
        daemon.release()
        await world.controller.reconciler.lastLaunch?.value
        #expect(daemon.requests("window.createTask").count == 1)
        #expect(world.task(task.id)?.operated?.launch?.number == 2)
    }

    /// Spec §7.3: iTerm2 coming back with the helper still there is reconciled on its snapshot, not a minute later.
    @Test func anItermReconnectIsReconciledAtOnce() throws {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        world.controller.handle(.itermDisconnected)
        #expect(world.run(run.id)?.state == .active, "no tab is gone while iTerm2 is")
        world.show([])
        #expect(world.run(run.id)?.state == .operatorOffline)
    }

    /// A worker that sits at a prompt after its task was accepted still has the prompt read, so the question reaches you
    /// (spec §H): probing covers every task with a worker tab, not only working or blocked ones.
    @Test func promptsAreProbedOnAcceptedTasksToo() async throws {
        for state in [OperatedState.accepted, .inReview, .published] {
            let project = OperatorServiceFixtures.project()
            let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
            let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-27", state: state, worktree: "/tmp/aiterm-wt")
            let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
            world.daemon.prompts["w1"] = .permission
            world.show([OperatorServiceFixtures.session("op", tag: run.id), OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, state: .needsInput)])
            world.controller.probePrompts()
            await world.controller.lastProbe?.value
            #expect(world.run(run.id)?.questions.last?.text == "Claude Code asks for permission", "\(state)")
            #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == true, "\(state)")
        }
    }

    /// A prompt read that fails because the helper is gone records nothing; the next pass asks again.
    @Test func aPromptReadThatFailsRecordsNoQuestionAndIsAskedAgain() async throws {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-26", state: .working, agent: .codex, worktree: "/tmp/aiterm-wt")
        let world = try makeWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        world.daemon.failing["session.prompt"] = .disconnected
        world.daemon.prompts["w1"] = .permission
        world.show([OperatorServiceFixtures.session("op", tag: run.id), OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, agent: .codex, state: .needsInput)])
        await world.controller.lastProbe?.value
        #expect(world.run(run.id)?.questions.isEmpty == true && world.notifications.posted.isEmpty)
        world.daemon.failing = [:]
        world.controller.probePrompts()
        await world.controller.lastProbe?.value
        #expect(world.run(run.id)?.questions.last?.text == "Codex asks for permission")
    }

    /// `start()` ticks every `reconcileInterval` and `stop()` ends it: the interval is injected, and what a
    /// tick does is waited for, never counted after a sleep.
    @Test func theLoopTicksEveryIntervalUntilItIsStopped() async throws {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        let op = OperatorServiceFixtures.session("op", tag: run.id)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) { ports in
            ports.now = { [clock] in clock.now }
            ports.reconcileInterval = .milliseconds(5)
        }
        world.show([op])
        world.live.sessions = []   // the tab is gone, with no event to say so
        world.controller.start()
        world.controller.start()
        await eventually(describing: "the loop to see the tab gone") { world.run(run.id)?.state == .operatorOffline }
        world.controller.stop()
        world.live.sessions = [op]
        try await Task.sleep(for: .milliseconds(100))
        #expect(world.run(run.id)?.state == .operatorOffline, "stopped: no tick brings it back")
        world.controller.start()
        await eventually(describing: "the loop to see the tab back") { world.run(run.id)?.state == .active }
        world.controller.stop()
    }
}
