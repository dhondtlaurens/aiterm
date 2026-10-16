import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// Possibly stalled, with several tasks at work: each task on its own clock.
@Suite struct StallWatchTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    func minutes(_ m: Double) -> Date { start.addingTimeInterval(m * 60) }

    func session(_ id: String, task: UUID, state: SessionState = .working, title: String = "Working") -> SessionInfo {
        SessionInfo(sessionId: id, windowId: "w-" + id, tabIndex: 0, taskId: task.uuidString, projectId: nil,
                    agent: .claude, model: nil, state: state, title: title, cwd: "/tmp")
    }

    /// Two workers launched at once. One keeps changing; the other goes quiet.
    func twoWorkers() -> (world: OperatedWorld, busy: UUID, quiet: UUID) {
        var world = OperatedWorld()
        let run = world.addRun()
        let busy = world.addTask("BUSY-1", run: run, state: .working), quiet = world.addTask("QUIET-1", run: run, state: .working)
        for id in [busy, quiet] { world.update(id) { $0.launch = LaunchAttempt(number: 1, requestedAt: start) } }
        return (world, busy, quiet)
    }

    @Test func oneBusyWorkerNeitherHidesNorFramesAQuietOne() {
        let (world, busy, quiet) = twoWorkers()
        var watch = StallWatch()
        watch.observe([session("a", task: busy), session("b", task: quiet)], at: minutes(0))
        watch.observe([session("a", task: busy, title: "Editing"), session("b", task: quiet)], at: minutes(15))
        #expect(watch.stalled(in: world.state, now: minutes(19)).isEmpty)
        #expect(watch.stalled(in: world.state, now: minutes(21)) == [quiet])
        #expect(watch.stalled(in: world.state, now: minutes(36)) == [busy, quiet])
    }

    @Test func aTaskWithNoSignYetCountsFromItsLaunch() {
        let (world, busy, _) = twoWorkers()
        var watch = StallWatch()
        watch.noteSign(of: busy, at: minutes(10))
        #expect(watch.stalled(in: world.state, now: minutes(20)).count == 1, "the quiet one, from its launch")
    }

    @Test func waitingOnYouStopsTheClockAndTheAnswerRestartsIt() {
        var (world, busy, quiet) = twoWorkers()
        var watch = StallWatch()
        watch.observe([session("a", task: busy), session("b", task: quiet)], at: minutes(0))
        world.update(quiet) { $0.flags.insert(.waitingOnYou) }
        watch.observe([session("a", task: busy), session("b", task: quiet, state: .needsInput)], at: minutes(1))
        #expect(!watch.stalled(in: world.state, now: minutes(30)).contains(quiet), "its time is yours")
        world.update(quiet) { $0.flags.remove(.waitingOnYou) }
        watch.observe([session("a", task: busy), session("b", task: quiet, state: .working)], at: minutes(30))
        #expect(!watch.stalled(in: world.state, now: minutes(45)).contains(quiet))
        #expect(watch.stalled(in: world.state, now: minutes(51)).contains(quiet))
    }

    @Test func aTakenOverOrUnlaunchedTaskIsNeverJudged() {
        var world = OperatedWorld()
        let run = world.addRun()
        let driven = world.addTask("D-1", run: run, state: .working)
        world.update(driven) { $0.takenOver = true; $0.launch = LaunchAttempt(number: 1, requestedAt: start) }
        let unlaunched = world.addTask("N-1", run: run, state: .working)
        world.update(unlaunched) { $0.launch = nil }
        #expect(StallWatch().stalled(in: world.state, now: minutes(120)).isEmpty)
    }

    @Test func theFlagIsSetOnceAndClearedOnTheNextSign() {
        var (world, busy, quiet) = twoWorkers()
        var watch = StallWatch()
        watch.observe([session("a", task: busy), session("b", task: quiet)], at: minutes(0))
        watch.noteSign(of: busy, at: minutes(20))
        let first = watch.flagChanges(in: world.state, now: minutes(21))
        #expect(first == StallWatch.Changes(flag: [quiet], clear: []))
        StallWatch.apply(first, to: &world.state)
        #expect(world.operated(quiet)?.flags.contains(.possiblyStalled) == true)
        #expect(watch.flagChanges(in: world.state, now: minutes(22)) == StallWatch.Changes(flag: [], clear: []), "flagged once")
        watch.observe([session("a", task: busy), session("b", task: quiet, title: "Thinking")], at: minutes(23))
        let second = watch.flagChanges(in: world.state, now: minutes(23))
        #expect(second == StallWatch.Changes(flag: [], clear: [quiet]))
        StallWatch.apply(second, to: &world.state)
        #expect(world.operated(quiet)?.flags.contains(.possiblyStalled) == false)
    }

    /// A session that closes is no sign of life; reconciliation, not the stall clock, deals with it.
    @Test func aSessionThatGoesAwayIsNoSign() {
        let (world, busy, quiet) = twoWorkers()
        var watch = StallWatch()
        watch.observe([session("a", task: busy), session("b", task: quiet)], at: minutes(0))
        watch.observe([session("a", task: busy)], at: minutes(19))
        #expect(watch.stalled(in: world.state, now: minutes(21)) == [busy, quiet])
    }

    /// A state holding one task twice judges and flags it once, as the scheduler keeps the first.
    @Test func aTaskHeldTwiceIsJudgedAndFlaggedOnce() {
        var (world, _, quiet) = twoWorkers()
        world.state.tasks.append(world.state.tasks.first { $0.id == quiet }!)
        let changes = StallWatch().flagChanges(in: world.state, now: minutes(21))
        #expect(changes.flag.filter { $0 == quiet }.count == 1)
    }
}
