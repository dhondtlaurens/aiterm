import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Broadcast "Broadcast fix" (2026-11-05): nothing woke the Operator when A's worker stopped after the Mac slept, and it
/// kept the broadcast going only with its own `sleep 600` loop; A's stall was found about 2 hours late. The watchdog wakes
/// it once a broadcast has been quiet `OperatorTiming.quietWake` with nobody at work: once per quiet spell.
@MainActor @Suite struct OperatorWatchdogTests {
    let project = OperatorServiceFixtures.project()
    let run: OperatorRun
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let woken = Woken()

    final class Woken { var runs: [UUID] = [] }

    init() {
        run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
    }

    /// area-A, its worker stopped on an API error after the Mac slept: idle, nothing working, nothing moving.
    func status(_ facts: TaskLiveFacts = TaskLiveFacts(status: .idle, lastMessage: "API Error: Connection error.", commitsAhead: 1,
                                                       stoppedOn: "it won't carry on by itself"),
                adjust: (inout RunStatus) -> Void = { _ in }) -> RunStatus {
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "area-A", state: .working)
        var status = RunStatus.build(state: OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), run: run.id,
                                     revision: 1, live: [task.id: facts])!
        adjust(&status)
        return status
    }

    final class Clock { var now: Date; init(_ now: Date) { self.now = now } }

    func watchdog(_ clock: Clock) -> OperatorWatchdog {
        let woken = self.woken
        return OperatorWatchdog(now: { clock.now }, wake: { woken.runs.append($0) })
    }

    func check(_ dog: OperatorWatchdog, _ status: RunStatus, state: OperatorRunState = .active, operatorWorking: Bool = false) {
        dog.check(run.id, status: status, state: state, operatorWorking: operatorWorking)
    }

    @Test func theWakeLineIsPlainAndSaysTheQuietTime() {
        #expect(OperatorTiming.quietWake == 600)
        #expect(OperatorWatchdog.reason == "nothing has moved for ten minutes")
        #expect(OperatorWaker.isPlain(OperatorWatchdog.reason))
        #expect(OperatorWaker.line(updates: 1, reason: .init(text: OperatorWatchdog.reason, colon: false))
                == "[AiTerm] nothing has moved for ten minutes, call run_status")
    }

    /// Ten quiet minutes with nobody at work wake the Operator once; not a minute sooner, and not again while it stays quiet.
    @Test func aQuietBroadcastWakesTheOperatorOncePerSpell() {
        let clock = Clock(now), dog = watchdog(clock), quiet = status()
        dog.observe(quiet, of: run.id)
        clock.now += OperatorTiming.quietWake - 60
        check(dog, quiet)
        #expect(woken.runs.isEmpty)
        clock.now += 60
        check(dog, quiet)
        #expect(woken.runs == [run.id])
        // The Operator reads, and the line it was woken with lands: neither re-arms it.
        dog.touched(run.id)
        clock.now += OperatorTiming.quietWake * 3
        check(dog, quiet)
        #expect(woken.runs == [run.id])
        // Something moves: a new spell, woken again once it is quiet that long.
        let moved = status(TaskLiveFacts(status: .idle, lastMessage: "Done.", commitsAhead: 2))
        dog.observe(moved, of: run.id)
        clock.now += OperatorTiming.quietWake
        check(dog, moved)
        #expect(woken.runs == [run.id, run.id])
    }

    /// Each event starts the quiet time again: a change in what run_status shows, a tool call, a wake line delivered.
    @Test func everyEventStartsTheQuietTimeAgain() {
        let clock = Clock(now), dog = watchdog(clock)
        dog.observe(status(), of: run.id)
        clock.now += OperatorTiming.quietWake - 1
        dog.touched(run.id)
        clock.now += OperatorTiming.quietWake - 1
        check(dog, status())
        dog.observe(status(TaskLiveFacts(status: .idle, lastMessage: "Done.", commitsAhead: 2)), of: run.id)
        clock.now += OperatorTiming.quietWake - 1
        check(dog, status(TaskLiveFacts(status: .idle, lastMessage: "Done.", commitsAhead: 2)))
        #expect(woken.runs.isEmpty)
    }

    /// AiTerm just started, or the broadcast was first seen: its quiet time starts then.
    @Test func aBroadcastFirstSeenIsNotQuietYet() {
        let clock = Clock(now), dog = watchdog(clock)
        check(dog, status())
        #expect(woken.runs.isEmpty)
        clock.now += OperatorTiming.quietWake
        check(dog, status())
        #expect(woken.runs == [run.id])
    }

    /// Somebody at work, on any of a task's tabs, is not quiet: a first worker working or opening, an extra tab (a
    /// reviewer) working beside an idle first worker, a job left running in the background, a test run under way; nor
    /// is the Operator's own turn, a paused broadcast or an ended one.
    @Test(arguments: [
        "working", "workingQuiet", "opening", "reviewerTab", "openingTab", "background", "testRun", "operatorTurn", "paused",
        "complete", "planning",
    ])
    func nobodyAtWorkIsTheOnlyQuiet(_ busy: String) {
        let clock = Clock(now), dog = watchdog(clock)
        var state = OperatorRunState.active, operatorWorking = false
        let line = status { status in
            switch busy {
            case "working": status.tasks[0].live = .working
            case "workingQuiet": status.tasks[0].live = .workingQuiet
            case "opening": status.tasks[0].opening = true
            case "reviewerTab": status.tasks[0].tabs = [RunStatus.TabLine(key: "review", agent: .codex, model: "m", live: .working)]
            case "openingTab": status.tasks[0].tabs = [RunStatus.TabLine(key: "review", agent: .codex, model: "m", opening: true)]
            case "background": status.tasks[0].background = ["scripts/test.sh all"]
            case "testRun": status.tasks[0].testActivities = [TestActivity(runId: "r", suite: "all", state: .running)]
            default: break
            }
        }
        switch busy {
        case "operatorTurn": operatorWorking = true
        case "paused": state = .paused
        case "complete": state = .complete
        case "planning": state = .planning
        default: break
        }
        dog.observe(line, of: run.id)
        clock.now += OperatorTiming.quietWake * 2
        check(dog, line, state: state, operatorWorking: operatorWorking)
        #expect(woken.runs.isEmpty, "\(busy)")
    }

    /// Work that just ended starts the quiet time: the ten minutes count from the last check that saw someone at work.
    @Test func quietTimeCountsFromTheLastWorkSeen() {
        let clock = Clock(now), dog = watchdog(clock)
        let working = status { $0.tasks[0].live = .working }, quiet = status()
        dog.observe(working, of: run.id)
        clock.now += OperatorTiming.quietWake * 2
        check(dog, working, operatorWorking: false)
        check(dog, quiet, operatorWorking: true)
        clock.now += OperatorTiming.quietWake - 1
        check(dog, quiet)
        #expect(woken.runs.isEmpty)
        clock.now += 1
        check(dog, quiet)
        #expect(woken.runs == [run.id])
    }

    /// An ended or forgotten broadcast is dropped: nothing of it fires later.
    @Test func aForgottenBroadcastNeverFires() {
        let clock = Clock(now), dog = watchdog(clock)
        dog.observe(status(), of: run.id)
        dog.forget(run.id)
        clock.now += OperatorTiming.quietWake
        check(dog, status(), state: .stopped)
        #expect(woken.runs.isEmpty)
    }

    /// Wired into the controller: area-A's worker stopped and idle, the Operator idle between turns, ten quiet minutes,
    /// and the reconcile tick types the line into the Operator's tab.
    @Test func theControllersTickWakesTheOperatorAfterTenQuietMinutes() async throws {
        let clock = TestClock.operators()
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "area-A", state: .working, worktree: "/tmp/aiterm-wt-a")
        // Launched long ago: its worker's opening is over, so nothing changes with the clock alone.
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now.addingTimeInterval(-3600),
                                              openedAt: clock.now.addingTimeInterval(-3600))
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task])) { ports in
            ports.clock.now = { clock.now }
        }
        world.show([OperatorServiceFixtures.session("op", tag: run.id), OperatorServiceFixtures.session("w1", window: "w9", tag: task.id)])
        world.controller.reconcileTick()
        // Its ended turn is read, and told, before the quiet time is counted.
        await world.settled()
        func quietLines() async -> [String] {
            await world.settled()
            return world.daemon.requests("session.deliver").compactMap { $0.params["text"] as? String }.filter { $0.contains("nothing has moved") }
        }
        clock.advance(by: OperatorTiming.quietWake - 60)
        world.controller.reconcileTick()
        #expect(await quietLines().isEmpty)
        clock.advance(by: 60)
        world.controller.reconcileTick()
        try await world.daemon.received("session.deliver")
        #expect(await quietLines() == ["[AiTerm] nothing has moved for ten minutes, call run_status"],
                "\(world.daemon.requests("session.deliver").compactMap { $0.params["text"] as? String })")
        clock.advance(by: OperatorTiming.quietWake * 2)
        world.controller.reconcileTick()
        #expect(await quietLines().count == 1, "once per quiet spell")
    }

    /// A turn of the Operator's that starts and ends between two ticks starts the quiet time again when it ends: no
    /// `nothing has moved` line right after it (found by the change's review).
    @Test func anOperatorTurnBetweenTicksStartsTheQuietTimeAgain() async throws {
        let clock = TestClock.operators()
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "area-A", state: .working, worktree: "/tmp/aiterm-wt-a")
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now.addingTimeInterval(-3600),
                                              openedAt: clock.now.addingTimeInterval(-3600))
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task])) { ports in
            ports.clock.now = { clock.now }
        }
        let worker = OperatorServiceFixtures.session("w1", window: "w9", tag: task.id)
        world.show([OperatorServiceFixtures.session("op", tag: run.id), worker])
        world.controller.reconcileTick()
        clock.advance(by: OperatorTiming.quietWake - 120)
        world.show([OperatorServiceFixtures.session("op", tag: run.id, state: .working), worker])
        clock.advance(by: 60)
        world.show([OperatorServiceFixtures.session("op", tag: run.id), worker])
        clock.advance(by: 60)
        world.controller.reconcileTick()
        try await Task.sleep(for: .milliseconds(50))
        await world.settled()
        let lines = world.daemon.requests("session.deliver").compactMap { $0.params["text"] as? String }
        #expect(!lines.contains { $0.contains("nothing has moved") }, "\(lines)")
    }
}
