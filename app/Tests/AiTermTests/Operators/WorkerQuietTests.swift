import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A worker whose session says working while its transcript has not grown for `liveQuietMinutes` (spec §H): the daemon's
/// state may have stuck, so `run_status` reads it `working?` and lists it as uncertain, on a task in any state.
@MainActor @Suite struct WorkerQuietTests {
    let clock = TestClock.operators()

    /// A task PLUTO-1 in `state` whose worker, in conversation `conv-1`, is `worker`, and the minute the world starts at.
    func makeWorld(_ state: OperatedState, worker: SessionState = .working, agent: AgentKind = .claude,
                   extraTab: Bool = false) throws -> (OperatorWorld, OperatorRun, TaskItem) {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: state, agent: agent, worktree: "/tmp/aiterm-wt")
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now, openedAt: clock.now)
        if extraTab {
            task.operated?.extraTabs = [ExtraTab(key: "review", agent: .codex, model: "gpt-6-mini", reasoning: nil, modelReason: "Tests.",
                                                 brief: "Write the tests.", launch: LaunchAttempt(number: 1, requestedAt: clock.now, openedAt: clock.now),
                                                 sessionId: "s-review")]
        }
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task])) { [clock] ports in
            ports.clock.now = { clock.now }
        }
        world.show(sessions(run, task, worker))
        return (world, run, task)
    }

    func sessions(_ run: OperatorRun, _ task: TaskItem, _ worker: SessionState) -> [SessionInfo] {
        var tabs = [OperatorServiceFixtures.session("op", window: "wo", tag: run.id),
                    OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, agent: task.agent.session, state: worker,
                                                    conversation: "conv-1")]
        if task.operated?.extraTabs.isEmpty == false {
            var review = OperatorServiceFixtures.session("s-review", window: "w9", tag: task.id, agent: .codex, state: .working,
                                                         conversation: "conv-r")
            review.tabIndex = 1
            review.tabKey = "review"
            tabs.append(review)
        }
        return tabs
    }

    /// The worker's transcript, last written `seconds` ago on the test's clock: `lines`, or an empty record.
    func writeTranscript(_ world: OperatorWorld, writtenAgo seconds: TimeInterval, lines: [String] = ["{}"],
                         agent: AgentKind = .claude, conversation: String = "conv-1") throws {
        let file = agent == .codex
            ? world.ports.home.appendingPathComponent(".codex/sessions/1970/01/12/rollout-1970-01-12T13-46-40-\(conversation).jsonl")
            : world.ports.home.appendingPathComponent(".claude/projects/-wt/\(conversation).jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: clock.now.addingTimeInterval(-seconds)], ofItemAtPath: file.path)
    }

    /// The test clock's time `seconds` on from now, as a transcript stamps its records.
    func stamp(_ seconds: TimeInterval = 0) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.string(from: clock.now.addingTimeInterval(seconds))
    }

    func claudeUse(_ id: String, at stamp: String) -> String {
        #"{"type":"assistant","isSidechain":false,"timestamp":"\#(stamp)","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"Bash","input":{}}]}}"#
    }

    func claudeResult(_ id: String, at stamp: String) -> String {
        #"{"type":"user","isSidechain":false,"timestamp":"\#(stamp)","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"ok"}]}}"#
    }

    func possiblyStalled(_ world: OperatorWorld, _ task: TaskItem) -> Bool {
        world.task(task.id)?.operated?.flags.contains(.possiblyStalled) == true
    }

    /// One reconcile tick, and what it read of the transcripts.
    func tick(_ world: OperatorWorld) async {
        world.controller.reconcileTick()
        await world.controller.quiet.lastRead?.value
    }

    func line(_ world: OperatorWorld, _ run: OperatorRun) throws -> RunStatus.TaskLine {
        let current = try #require(world.run(run.id))
        return try #require(world.controller.status(of: current)?.tasks.first)
    }

    func uncertain(_ world: OperatorWorld, _ run: OperatorRun) throws -> [String] {
        let current = try #require(world.run(run.id))
        return try #require(world.controller.status(of: current)).obligations.uncertain
    }

    /// The FE run's case: an inReview task whose worker showed working for a long time while it did nothing.
    @Test func aQuietWorkerOnAnInReviewTaskIsUncertain() async throws {
        let (world, run, _) = try makeWorld(.inReview)
        try writeTranscript(world, writtenAgo: 0)
        clock.advance(by: 180)
        await tick(world)
        #expect(try line(world, run).live == .workingQuiet)
        #expect(try uncertain(world, run) == ["PLUTO-1"])
    }

    @Test func aGrowingTranscriptStaysWorking() async throws {
        let (world, run, _) = try makeWorld(.inReview)
        try writeTranscript(world, writtenAgo: 0)
        clock.advance(by: 180)
        try writeTranscript(world, writtenAgo: 30)
        await tick(world)
        #expect(try line(world, run).live == .working)
        #expect(try uncertain(world, run).isEmpty)
    }

    /// A worker that only just went to work has not had its two minutes, whatever its transcript's age.
    @Test func aTurnJustBegunIsNotQuiet() async throws {
        let (world, run, _) = try makeWorld(.working)
        try writeTranscript(world, writtenAgo: 3600)
        clock.advance(by: 60)
        await tick(world)
        #expect(try line(world, run).live == .working)
        clock.advance(by: 90)
        await tick(world)
        #expect(try line(world, run).live == .workingQuiet)
    }

    /// Its transcript growing again, or its session leaving working, ends it; and a worker with no transcript to read is
    /// taken at the session's word.
    @Test func aWorkerThatWritesAgainOrStopsIsNoLongerQuiet() async throws {
        let (world, run, task) = try makeWorld(.accepted)
        try writeTranscript(world, writtenAgo: 0)
        clock.advance(by: 180)
        await tick(world)
        #expect(try line(world, run).live == .workingQuiet)
        try writeTranscript(world, writtenAgo: 5)
        await tick(world)
        #expect(try line(world, run).live == .working)
        clock.advance(by: 180)
        await tick(world)
        #expect(try line(world, run).live == .workingQuiet)
        world.show(sessions(run, task, .idle))
        #expect(try line(world, run).live == .idle, "no longer working")
        #expect(try uncertain(world, run).isEmpty)
    }

    /// A worker whose turn ended while its subagent still runs (26 Oct 2026): the daemon holds it at working, lists what
    /// runs and says when its subagents last wrote. Not quiet while one writes, its line names the subagent it waits on;
    /// quiet once they too have said nothing as long.
    @Test func aWorkerWaitingOnASubagentThatWritesIsNotQuiet() async throws {
        let (world, run, task) = try makeWorld(.working)
        try writeTranscript(world, writtenAgo: 0)
        clock.advance(by: 180)
        var waiting = sessions(run, task, .working)
        waiting[1].background = [BackgroundJob(kind: .subagent, text: "Review the fix"), BackgroundJob(kind: .shell, text: "scripts/test.sh")]
        waiting[1].subagentsWrittenAt = clock.now.addingTimeInterval(-20).timeIntervalSince1970
        world.show(waiting)
        await tick(world)
        #expect(try line(world, run).live == .working)
        #expect(try uncertain(world, run).isEmpty)
        #expect(try line(world, run).background == ["Review the fix"])
        clock.advance(by: 120)
        await tick(world)
        #expect(try line(world, run).live == .workingQuiet)
    }

    @Test func aWorkerWithNoTranscriptIsTakenAtTheSessionsWord() async throws {
        let (world, run, _) = try makeWorld(.inReview)
        clock.advance(by: 600)
        await tick(world)
        #expect(try line(world, run).live == .working)
    }

    /// Its subagents' writes add to its own transcript's, and never stand in for one not found.
    @Test func aWorkerWithNoTranscriptIsTakenAtTheSessionsWordWhateverItsSubagentsWrote() async throws {
        let (world, run, task) = try makeWorld(.inReview)
        var waiting = sessions(run, task, .working)
        waiting[1].subagentsWrittenAt = clock.now.addingTimeInterval(-600).timeIntervalSince1970
        world.show(waiting)
        clock.advance(by: 600)
        await tick(world)
        #expect(try line(world, run).live == .working)
    }

    /// The case seen (26 Oct 2026): a Bash call that waited minutes on the machine-wide test lock writes nothing until it
    /// returns. While it runs its worker is at work, for up to `openCallMinutes` from the call's start; past that, a call
    /// that hung is quiet like any silence.
    @Test func aWorkerInALongToolCallIsNotQuietUntilTheCap() async throws {
        let (world, run, _) = try makeWorld(.working)
        try writeTranscript(world, writtenAgo: 0, lines: [claudeUse("toolu_a", at: stamp())])
        clock.advance(by: 300)
        await tick(world)
        #expect(try line(world, run).live == .working)
        #expect(try uncertain(world, run).isEmpty)
        clock.advance(by: Double(OperatorTiming.openCallMinutes) * 60 - 300)
        await tick(world)
        #expect(try line(world, run).live == .workingQuiet)
        #expect(try uncertain(world, run) == ["PLUTO-1"])
    }

    /// The call's result ends what it held: from then the transcript's age alone says.
    @Test func aToolCallsResultEndsItsHold() async throws {
        let (world, run, _) = try makeWorld(.working)
        let use = claudeUse("toolu_a", at: stamp())
        try writeTranscript(world, writtenAgo: 0, lines: [use])
        clock.advance(by: 240)
        await tick(world)
        #expect(try line(world, run).live == .working)
        try writeTranscript(world, writtenAgo: 0, lines: [use, claudeResult("toolu_a", at: stamp())])
        clock.advance(by: 150)
        await tick(world)
        #expect(try line(world, run).live == .workingQuiet)
    }

    /// Codex the same: a function call (here a sleep of eight minutes) is open until its output names its call id.
    @Test func aCodexWorkerInALongFunctionCallIsNotQuiet() async throws {
        let (world, run, _) = try makeWorld(.working, agent: .codex)
        let call = #"{"timestamp":"\#(stamp())","type":"response_item","payload":{"type":"function_call","call_id":"call_s","name":"sleep","arguments":"{}"}}"#
        try writeTranscript(world, writtenAgo: 0, lines: [call], agent: .codex)
        clock.advance(by: 480)
        await tick(world)
        #expect(try line(world, run).live == .working)
        let output = #"{"timestamp":"\#(stamp())","type":"response_item","payload":{"type":"function_call_output","call_id":"call_s","output":"done"}}"#
        try writeTranscript(world, writtenAgo: 0, lines: [call, output], agent: .codex)
        clock.advance(by: 150)
        await tick(world)
        #expect(try line(world, run).live == .workingQuiet)
    }

    /// A working Codex worker whose session the daemon never sees change (it installs no hooks AiTerm reads mid-turn):
    /// its rollout's growth is its sign of life, so it is not possibly stalled while it writes, and once it has said nothing
    /// for `stallAfter` and is flagged, its next write clears the flag.
    @Test func aGrowingTranscriptKeepsAWorkerFromPossiblyStalled() async throws {
        let (world, _, task) = try makeWorld(.working, agent: .codex)
        try writeTranscript(world, writtenAgo: 0, agent: .codex)
        await tick(world)
        for _ in 0..<5 {
            clock.advance(by: 300)
            try writeTranscript(world, writtenAgo: 10, agent: .codex)
            await tick(world)
        }
        #expect(!possiblyStalled(world, task), "25 minutes of writes")
        clock.advance(by: OperatorTiming.stallAfter + 60)
        await tick(world)
        #expect(possiblyStalled(world, task))
        try writeTranscript(world, writtenAgo: 10, agent: .codex)
        await tick(world)
        clock.advance(by: 60)
        await tick(world)
        #expect(!possiblyStalled(world, task))
    }

    /// Each tab's transcript is a sign on its own clock: the extra tab's writes never clear a stall its silent first
    /// worker is in, and the flag clears once that one writes too.
    @Test func aTabsTranscriptClearsAStallForThatTabOnly() async throws {
        let (world, _, task) = try makeWorld(.working, extraTab: true)
        await tick(world)
        clock.advance(by: OperatorTiming.stallAfter + 60)
        await tick(world)
        #expect(possiblyStalled(world, task))
        try writeTranscript(world, writtenAgo: 10, agent: .codex, conversation: "conv-r")
        await tick(world)
        clock.advance(by: 60)
        await tick(world)
        #expect(possiblyStalled(world, task), "its first worker still said nothing")
        try writeTranscript(world, writtenAgo: 10)
        await tick(world)
        clock.advance(by: 60)
        await tick(world)
        #expect(!possiblyStalled(world, task))
    }

    /// A task you took over is yours: its worker's quiet is not the Operator's to doubt.
    @Test func aTakenOverTaskIsNotJudged() async throws {
        let (world, run, task) = try makeWorld(.working)
        try writeTranscript(world, writtenAgo: 0)
        world.workspace.mutate { $0.updateOperated(task.id) { $0.takenOver = true } }
        clock.advance(by: 180)
        await tick(world)
        #expect(try line(world, run).live == .working)
    }

    /// The Operator is woken when a worker turns quiet: `run_status` changed, and the generic line says so.
    @Test func theOperatorIsWokenWhenAWorkerTurnsQuiet() async throws {
        let (world, _, _) = try makeWorld(.inReview)
        try writeTranscript(world, writtenAgo: 0)
        clock.advance(by: 180)
        await tick(world)
        #expect(await eventually(describing: "the Operator told") {
            world.daemon.requests("session.deliver").compactMap { $0.params["text"] as? String }
                .contains("[AiTerm] updates waiting, call run_status")
        })
    }
    @Test func aLongQueueWaitWithItsOwnCommandAliveIsNeitherQuietNorStalled() async throws {
        let (world, run, task) = try makeWorld(.working)
        try writeTranscript(world, writtenAgo: 0)
        var tabs = sessions(run, task, .working)
        tabs[1].testActivity = TestActivity(runId: "own", suite: "all", state: .queued, queuePosition: 2)
        world.show(tabs)
        clock.advance(by: 1800)
        await tick(world)
        #expect(try uncertain(world, run).isEmpty)
        #expect(!possiblyStalled(world, task))
        #expect(try line(world, run).testActivities?.first?.queuePosition == 2)
    }

    @Test func aTestOwnedByAnotherWorkerHoldsTaskUncertaintyUntilItCompletes() async throws {
        let (world, run, task) = try makeWorld(.working, extraTab: true)
        try writeTranscript(world, writtenAgo: 0)
        var tabs = sessions(run, task, .working)
        tabs[2].testActivity = TestActivity(runId: "own", suite: "all", state: .running)
        world.show(tabs)
        clock.advance(by: 1800)
        await tick(world)
        #expect(try uncertain(world, run).isEmpty)
        #expect(!possiblyStalled(world, task))
        tabs[2].testActivity = TestActivity(runId: "own", suite: "all", state: .completed, exitCode: 0)
        world.show(tabs)
        await tick(world)
        #expect(try uncertain(world, run).isEmpty)
        clock.advance(by: 180)
        await tick(world)
        #expect(try uncertain(world, run) == ["PLUTO-1"])
    }

}
