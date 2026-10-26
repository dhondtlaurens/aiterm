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
    func makeWorld(_ state: OperatedState, worker: SessionState = .working) throws -> (OperatorWorld, OperatorRun, TaskItem) {
        let project = OperatorServiceFixtures.project()
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-1", state: state, worktree: "/tmp/aiterm-wt")
        task.operated?.launch = LaunchAttempt(number: 1, requestedAt: clock.now, openedAt: clock.now)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task])) { [clock] ports in
            ports.now = { clock.now }
        }
        world.show(sessions(run, task, worker))
        return (world, run, task)
    }

    func sessions(_ run: OperatorRun, _ task: TaskItem, _ worker: SessionState) -> [SessionInfo] {
        [OperatorServiceFixtures.session("op", window: "wo", tag: run.id),
         OperatorServiceFixtures.session("w1", window: "w9", tag: task.id, state: worker, conversation: "conv-1")]
    }

    /// The worker's transcript, last written `seconds` ago on the test's clock.
    func writeTranscript(_ world: OperatorWorld, writtenAgo seconds: TimeInterval) throws {
        let folder = world.ports.home.appendingPathComponent(".claude/projects/-wt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("conv-1.jsonl")
        try Data("{}\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: clock.now.addingTimeInterval(-seconds)], ofItemAtPath: file.path)
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
    /// runs and says when its subagents last wrote. Not quiet while one writes, its line says what it waits on; quiet once
    /// they too have said nothing as long.
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
        #expect(try line(world, run).background == ["Review the fix", "scripts/test.sh"])
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
}
