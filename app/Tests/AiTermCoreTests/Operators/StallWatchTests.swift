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
        for id in [busy, quiet] { world.state.updateOperated(id) { $0.launch = LaunchAttempt(number: 1, requestedAt: start) } }
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
        world.state.updateOperated(quiet) { $0.flags.insert(.waitingOnYou) }
        watch.observe([session("a", task: busy), session("b", task: quiet, state: .needsInput)], at: minutes(1))
        #expect(!watch.stalled(in: world.state, now: minutes(30)).contains(quiet), "its time is yours")
        world.state.updateOperated(quiet) { $0.flags.remove(.waitingOnYou) }
        watch.observe([session("a", task: busy), session("b", task: quiet, state: .working)], at: minutes(30))
        #expect(!watch.stalled(in: world.state, now: minutes(45)).contains(quiet))
        #expect(watch.stalled(in: world.state, now: minutes(51)).contains(quiet))
    }

    @Test func aTakenOverOrUnlaunchedTaskIsNeverJudged() {
        var world = OperatedWorld()
        let run = world.addRun()
        let driven = world.addTask("D-1", run: run, state: .working)
        world.state.updateOperated(driven) { $0.takenOver = true; $0.launch = LaunchAttempt(number: 1, requestedAt: start) }
        let unlaunched = world.addTask("N-1", run: run, state: .working)
        world.state.updateOperated(unlaunched) { $0.launch = nil }
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

    /// A task `settle` has seen: working, a quiet agent tab observed at minute 0 (its busy sibling is judged too, so these look at `task` alone).
    func quietWorker() -> (world: OperatedWorld, task: UUID, watch: StallWatch) {
        let (world, _, quiet) = twoWorkers()
        var watch = StallWatch()
        watch.observe([session("b", task: quiet)], at: minutes(0))
        watch.settle(in: world.state, at: minutes(0))
        return (world, quiet, watch)
    }

    @Test func aTaskResumedAfterAThirtyMinuteBlockStartsAFreshClock() {
        var (world, task, watch) = quietWorker()
        world.state.updateOperated(task) { $0.state = .blocked }
        watch.settle(in: world.state, at: minutes(29))
        world.state.updateOperated(task) { $0.state = .working }
        watch.settle(in: world.state, at: minutes(30))
        #expect(!watch.stalled(in: world.state, now: minutes(31)).contains(task))
        #expect(!watch.stalled(in: world.state, now: minutes(48)).contains(task))
        #expect(watch.stalled(in: world.state, now: minutes(50)).contains(task))
    }

    @Test func aRelaunchCountsFromItsOwnRequest() {
        var (world, task, watch) = quietWorker()
        world.state.updateOperated(task) { $0.launch = LaunchAttempt(number: 2, requestedAt: minutes(25)) }
        watch.settle(in: world.state, at: minutes(25))
        #expect(!watch.stalled(in: world.state, now: minutes(26)).contains(task))
        #expect(watch.stalled(in: world.state, now: minutes(46)).contains(task))
    }

    @Test func clearingWaitingOnYouWithTheSessionUnchangedStartsAFreshClock() {
        var (world, task, watch) = quietWorker()
        world.state.updateOperated(task) { $0.flags.insert(.waitingOnYou) }
        watch.observe([session("b", task: task)], at: minutes(39))
        watch.settle(in: world.state, at: minutes(39))
        world.state.updateOperated(task) { $0.flags.remove(.waitingOnYou) }
        watch.observe([session("b", task: task)], at: minutes(40))
        watch.settle(in: world.state, at: minutes(40))
        #expect(!watch.stalled(in: world.state, now: minutes(41)).contains(task))
        #expect(!watch.stalled(in: world.state, now: minutes(58)).contains(task))
        #expect(watch.stalled(in: world.state, now: minutes(59)).contains(task))
    }

    @Test func aShellTabInTheTaskIsNoSign() {
        let (world, _, quiet) = twoWorkers()
        var watch = StallWatch()
        var shell = session("sh", task: quiet)
        shell.agent = .shell
        watch.observe([shell], at: minutes(0))
        shell.title = "~/project"
        watch.observe([shell], at: minutes(15))
        #expect(watch.stalled(in: world.state, now: minutes(21)).contains(quiet), "counted from its launch")
    }

    @Test func aTaskGoneFromTheStateIsForgotten() {
        var (world, task, watch) = quietWorker()
        watch.noteSign(of: task, at: minutes(30))
        let kept = world.state.tasks
        world.state.tasks.removeAll { $0.id == task }
        watch.settle(in: world.state, at: minutes(31))
        world.state.tasks = kept
        #expect(watch.stalled(in: world.state, now: minutes(40)).contains(task), "its sign at 30 was dropped, so from its launch")
    }

    // -- a task with an extra worker tab (`open_tab`) -------------------------------------------

    /// One working task launched at `start`, with an extra tab `review` asked for then too.
    func twoTabs() -> (world: OperatedWorld, task: UUID) {
        var world = OperatedWorld()
        let task = world.addTask("TWO-1", run: world.addRun(), state: .working)
        world.state.updateOperated(task) { operated in
            operated.launch = LaunchAttempt(number: 1, requestedAt: start, openedAt: start)
            operated.extraTabs = [ExtraTab(key: "review", agent: .codex, model: "gpt-6-mini", reasoning: nil, modelReason: "Tests.",
                                           brief: "Write the tests.", launch: LaunchAttempt(number: 1, requestedAt: start, openedAt: start),
                                           sessionId: "r")]
        }
        return (world, task)
    }

    func extra(_ task: UUID, state: SessionState = .working, title: String = "Working") -> SessionInfo {
        var tab = session("r", task: task, state: state, title: title)
        tab.agent = .codex
        tab.tabIndex = 1
        tab.tabKey = "review"
        return tab
    }

    /// Each tab on its own clock: a busy tab that goes quiet is a stall, however much the other one does.
    @Test func aQuietBusyTabIsNoticedWhileTheOtherTabKeepsChanging() {
        let (world, task) = twoTabs()
        var first = StallWatch(), second = StallWatch()
        first.observe([session("a", task: task), extra(task)], at: minutes(0))
        second.observe([session("a", task: task), extra(task)], at: minutes(0))
        for minute in stride(from: 5.0, through: 20, by: 5) {
            first.observe([session("a", task: task), extra(task, title: "Step \(minute)")], at: minutes(minute))
            second.observe([session("a", task: task, title: "Step \(minute)"), extra(task)], at: minutes(minute))
        }
        #expect(first.stalled(in: world.state, now: minutes(21)) == [task], "the first worker went quiet")
        #expect(second.stalled(in: world.state, now: minutes(21)) == [task], "the extra tab went quiet")
    }

    /// A tab whose turn ended is not stalled while another is at work; once none is, the latest sign of any counts.
    @Test func aTabIdleAtItsPromptIsNoStallWhileAnotherWorks() {
        let (world, task) = twoTabs()
        var watch = StallWatch()
        watch.observe([session("a", task: task), extra(task, state: .idle)], at: minutes(0))
        watch.observe([session("a", task: task, title: "Editing"), extra(task, state: .idle)], at: minutes(15))
        #expect(watch.stalled(in: world.state, now: minutes(30)).isEmpty)
        watch.observe([session("a", task: task, state: .idle), extra(task, state: .idle)], at: minutes(30))
        #expect(watch.stalled(in: world.state, now: minutes(49)).isEmpty, "every tab ended its turn: counted from the last sign")
        #expect(watch.stalled(in: world.state, now: minutes(50)) == [task])
    }

    /// An extra tab asked for that never showed counts as at work from its request: the task is noticed.
    @Test func anExtraTabThatNeverOpensIsAStallFromItsRequest() {
        var (world, task) = twoTabs()
        world.state.updateOperated(task) { operated in
            operated.extraTabs[0].sessionId = nil
            operated.extraTabs[0].launch = LaunchAttempt(number: 1, requestedAt: minutes(5))
        }
        var watch = StallWatch()
        for minute in stride(from: 0.0, through: 20, by: 5) {
            watch.observe([session("a", task: task, title: "Step \(minute)")], at: minutes(minute))
        }
        #expect(watch.stalled(in: world.state, now: minutes(24)).isEmpty)
        #expect(watch.stalled(in: world.state, now: minutes(25)) == [task])
    }

    /// A task coming back to work counts every tab from then, not from a sign before it.
    @Test func aTaskBackAtWorkRestartsEveryTabsClock() {
        var (world, task) = twoTabs()
        var watch = StallWatch()
        watch.observe([session("a", task: task), extra(task)], at: minutes(0))
        world.state.updateOperated(task) { $0.takenOver = true }
        watch.settle(in: world.state, at: minutes(30))
        world.state.updateOperated(task) { $0.takenOver = false }
        #expect(watch.stalled(in: world.state, now: minutes(49)).isEmpty)
        #expect(watch.stalled(in: world.state, now: minutes(50)) == [task])
    }

    /// A sign noted for one tab (its transcript grew, or a tool call it started still runs) restarts that tab's clock
    /// alone: a silent tab beside it is still noticed, and the task clears once each busy tab showed one.
    @Test func aSignNotedForOneTabRestartsOnlyThatTabsClock() {
        let (world, task) = twoTabs()
        var watch = StallWatch()
        watch.observe([session("a", task: task), extra(task)], at: minutes(0))
        watch.noteSign(of: task, tab: "review", at: minutes(15))
        #expect(watch.stalled(in: world.state, now: minutes(21)) == [task], "the first worker said nothing")
        watch.noteSign(of: task, tab: WorkerTab.firstKey, at: minutes(21))
        #expect(watch.stalled(in: world.state, now: minutes(22)).isEmpty)
        #expect(watch.stalled(in: world.state, now: minutes(35)) == [task], "the extra tab's sign is 20 minutes old")
        watch.noteSign(of: task, tab: "review", at: minutes(35))
        #expect(watch.stalled(in: world.state, now: minutes(36)).isEmpty)
    }

    // -- a worker that says working but has gone quiet (spec §H) ------------------------------------------

    /// A transcript that grew less than `liveQuietMinutes` ago is a worker at work; older, and the session's "working" is
    /// not to be trusted. What it grew at is read against when the session started working: a turn just begun has not
    /// had its two minutes yet, whatever the transcript's age.
    @Test func aTranscriptQuietForTheLiveWindowIsQuietWhileWorking() {
        let now = minutes(10), window = Double(OperatorTiming.liveQuietMinutes)
        func quiet(grew: Double?, since: Double?) -> Bool {
            StallWatch.isQuietWhileWorking(transcriptGrewAt: grew.map(minutes), sessionWorkingSince: since.map(minutes), now: now)
        }
        #expect(quiet(grew: 10 - window - 1, since: 0))
        #expect(quiet(grew: 10 - window, since: 0), "exactly the window is quiet")
        #expect(!quiet(grew: 10 - window + 0.5, since: 0))
        #expect(!quiet(grew: 0, since: 10 - window + 0.5), "the turn only just began")
        #expect(quiet(grew: 0, since: nil), "no start is known: the transcript alone says")
        #expect(!quiet(grew: nil, since: 0), "no transcript to read says nothing")
        #expect(!quiet(grew: nil, since: nil))
    }

    /// A tool call that started and has no result yet writes nothing until it returns: its worker is not quiet, for
    /// `openCallMinutes` from the call's start. Past that, its transcript's age alone says.
    @Test func aRunningToolCallIsNotQuietUntilItsCap() {
        let cap = Double(OperatorTiming.openCallMinutes)
        func quiet(callSince: Double?, now: Double) -> Bool {
            StallWatch.isQuietWhileWorking(transcriptGrewAt: minutes(0), sessionWorkingSince: minutes(0),
                                           callOpenSince: callSince.map(minutes), now: minutes(now))
        }
        #expect(quiet(callSince: nil, now: 5))
        #expect(!quiet(callSince: 0, now: 5), "the call still runs")
        #expect(!quiet(callSince: 0, now: cap - 0.5))
        #expect(quiet(callSince: 0, now: cap), "a call that long may have hung")
        #expect(!StallWatch.isQuietWhileWorking(transcriptGrewAt: nil, sessionWorkingSince: minutes(0), callOpenSince: minutes(0),
                                                now: minutes(cap + 5)), "no transcript to read still says nothing")
    }
    @Test func aLiveQueuedOwnCommandRestartsOnlyItsWorkersStallClock() {
        let (world, busy, quiet) = twoWorkers()
        var watch = StallWatch(), waiting = session("b", task: quiet)
        waiting.testActivity = TestActivity(runId: "own", suite: "all", state: .queued, queuePosition: 2)
        watch.observe([session("a", task: busy), waiting], at: minutes(0))
        watch.observe([session("a", task: busy), waiting], at: minutes(40))
        #expect(!watch.stalled(in: world.state, now: minutes(40)).contains(quiet))
        #expect(watch.stalled(in: world.state, now: minutes(40)).contains(busy))
    }

    @Test func aLiveTaskTestHoldsTheExtraWorkersClockUntilItsOwnCompletion() {
        let (world, task) = twoTabs()
        var watch = StallWatch(), main = session("a", task: task, state: .done)
        main.testActivity = TestActivity(runId: "own", suite: "all", state: .queued)
        watch.observe([main, extra(task)], at: minutes(0))
        watch.observe([main, extra(task)], at: minutes(40))
        #expect(!watch.stalled(in: world.state, now: minutes(40)).contains(task))
        main.testActivity = TestActivity(runId: "own", suite: "all", state: .completed, exitCode: 0)
        watch.observe([main, extra(task)], at: minutes(41))
        #expect(!watch.stalled(in: world.state, now: minutes(42)).contains(task))
        watch.observe([main, extra(task)], at: minutes(60))
        #expect(!watch.stalled(in: world.state, now: minutes(60)).contains(task))
        watch.observe([main, extra(task)], at: minutes(62))
        #expect(watch.stalled(in: world.state, now: minutes(62)).contains(task))
    }

}
