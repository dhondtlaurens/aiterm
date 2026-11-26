import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// Which scheduled run is due: the latest missed time once, nothing from before `scheduledFrom`, one run at a time.
@Suite struct ScheduleDecisionTests {
    static let calendar = CronTests.brussels
    static func at(_ text: String) -> Date { CronTests.at(text) }

    /// A Monday-9:00 schedule created on Monday 23 Nov 2026 at 08:00.
    func world(cron: String = "0 9 * * 1", from: String = "2026-11-23 08:00") -> (SignalWorld, UUID) {
        var world = SignalWorld()
        let id = world.scheduled(cron: cron, from: Self.at(from))
        return (world, id)
    }

    func decide(_ world: SignalWorld, now: String, mayAct: @escaping (Signal) -> Bool = { _ in true },
                pending: Set<UUID> = []) -> ScheduleDecision.Outcome {
        ScheduleDecision.decide(signals: world.state.signals, cursors: world.state.scheduleCursors,
                                tasks: world.state.tasks, archive: world.state.archive.map(\.task), projects: world.state.projects,
                                now: Self.at(now), calendar: Self.calendar, mayAct: mayAct, pending: pending)
    }

    /// A project signal on the same Monday-9:00 schedule in the world's project, done when the person decides.
    func projectSchedule(_ world: inout SignalWorld, from: String = "2026-11-23 08:00") -> UUID {
        var signal = Signal.project(name: "Weekly review", createdAt: Self.at(from),
                                    start: SignalTrigger(source: .schedule, query: "0 9 * * 1", project: world.project.id),
                                    agent: SignalWorld.agent)
        signal.scheduledFrom = Self.at(from)
        world.state.signals.append(signal)
        return signal.id
    }

    @Test func aTimeIsDueOnceItPasses() {
        let (world, id) = world()
        #expect(decide(world, now: "2026-11-23 08:59").due.isEmpty)
        let outcome = decide(world, now: "2026-11-23 09:00")
        #expect(outcome.due == [.init(signal: id, run: SignalRunRef(signal: id, at: Self.at("2026-11-23 09:00")), project: world.project.id)])
        #expect(outcome.cursors[id] == Self.at("2026-11-23 09:00") && outcome.skipped.isEmpty)
    }

    @Test func theCursorNeverFiresATimeTwice() {
        var (world, id) = world()
        world.state.scheduleCursors[id] = Self.at("2026-11-23 09:00")
        let outcome = decide(world, now: "2026-11-23 09:30")
        #expect(outcome.due.isEmpty && outcome.skipped.isEmpty && outcome.cursors.isEmpty)
    }

    @Test func afterTwoMissedTimesOnlyTheLatestRuns() {
        var (world, id) = world()
        world.state.scheduleCursors[id] = Self.at("2026-11-23 09:00")
        // Closed through 30 Nov and 7 Dec; opened on 8 Dec.
        let outcome = decide(world, now: "2026-12-08 10:00")
        #expect(outcome.due.map(\.run.at) == [Self.at("2026-12-07 09:00")])
        #expect(outcome.cursors[id] == Self.at("2026-12-07 09:00"))
    }

    @Test func nothingFromBeforeScheduledFromRuns() {
        // Created at 09:30 on a Monday: today's 09:00 was before it.
        let (world, _) = world(from: "2026-11-23 09:30")
        #expect(decide(world, now: "2026-11-23 10:00").due.isEmpty)
        #expect(decide(world, now: "2026-11-30 09:00").due.count == 1)
    }

    @Test func aSignalSwitchedOffRunsNothing() {
        var (world, _) = world()
        world.state.signals[0].enabled = false
        let outcome = decide(world, now: "2026-11-23 09:00")
        #expect(outcome.due.isEmpty && outcome.cursors.isEmpty)
    }

    @Test func pausedRunsNothingAndResumingRunsTheLatestMissOnce() {
        let (world, id) = world()
        let paused = decide(world, now: "2026-11-23 09:00", mayAct: { _ in false })
        #expect(paused.due.isEmpty && paused.cursors.isEmpty)
        let resumed = decide(world, now: "2026-12-01 12:00")
        #expect(resumed.due.map(\.run.at) == [Self.at("2026-11-30 09:00")] && resumed.cursors[id] == Self.at("2026-11-30 09:00"))
    }

    @Test func anUnfinishedPreviousRunSkipsTheFiring() {
        var (world, id) = world()
        let task = world.workingTask(signal: id)
        world.state.updateSignalTask(task) { $0.scheduledRun = SignalRunRef(signal: id, at: Self.at("2026-11-16 09:00")) }
        let outcome = decide(world, now: "2026-11-23 09:00")
        #expect(outcome.due.isEmpty)
        #expect(outcome.skipped == [.init(signal: id, run: SignalRunRef(signal: id, at: Self.at("2026-11-23 09:00")),
                                         reason: "The last run is still unfinished.")])
        #expect(outcome.cursors[id] == Self.at("2026-11-23 09:00"))
    }

    @Test func aRunAnotherSignalContinuedStillBlocksItsSchedule() {
        var (world, id) = world()
        let other = world.signal(name: "My merge requests", start: SignalTrigger(source: .gitLab, query: "assignee:@me"),
                                 done: SignalTrigger(source: .gitLab, query: "state:merged"))
        let task = world.workingTask(signal: id)
        let stage = SignalStage(signal: other, item: .request(remote: "https://git.example/shop/web", number: 7),
                                matchedAt: Self.at("2026-11-17 10:00"), configuration: world.state.signal(id: other)!)
        world.state.updateSignalTask(task) { record in
            record.scheduledRun = SignalRunRef(signal: id, at: Self.at("2026-11-16 09:00"))
            record.phase = .watching
            record = try! SignalTransitions.apply(.matched(stage), to: record, at: Self.at("2026-11-17 10:00"))
        }
        #expect(world.state.signalItem(id: task)?.signalTask?.current.signal == other)
        #expect(decide(world, now: "2026-11-23 09:00").skipped.count == 1)
    }

    @Test func aFinishedPreviousRunDoesNotBlock() {
        var (world, id) = world()
        let task = world.workingTask(signal: id)
        world.state.updateSignalTask(task) { record in
            record.scheduledRun = SignalRunRef(signal: id, at: Self.at("2026-11-16 09:00"))
            record.phase = .done; record.thenApplied = true
        }
        #expect(decide(world, now: "2026-11-23 09:00").due.count == 1)
    }

    @Test func aTaskTakenOverNoLongerBlocks() {
        var (world, id) = world()
        let task = world.workingTask(signal: id)
        world.state.updateSignalTask(task) { $0.scheduledRun = SignalRunRef(signal: id, at: Self.at("2026-11-16 09:00")) }
        world.state.takeOver(task)
        #expect(decide(world, now: "2026-11-23 09:00").due.count == 1)
    }

    /// The scheduler's gate is per signal: a paused Operator holds its own schedules, cursor and all, and a project
    /// signal's runs carry on.
    @Test func aPausedOperatorStopsOnlyOperatorSchedules() {
        var (world, operatorSignal) = world()
        let projectSignal = projectSchedule(&world)
        let outcome = decide(world, now: "2026-11-23 09:00", mayAct: { $0.isProject })
        #expect(outcome.due.map(\.signal) == [projectSignal] && outcome.skipped.isEmpty)
        #expect(outcome.cursors[operatorSignal] == nil && outcome.cursors[projectSignal] == Self.at("2026-11-23 09:00"))
    }

    /// A project signal's run is unfinished until its Done is reached or its task is archived (O3).
    @Test func aMarkedRunBlocksItsSignalUntilDoneOrArchived() throws {
        var world = SignalWorld()
        let id = projectSchedule(&world)
        let task = world.markedTask(signal: id, item: .run(SignalRunRef(signal: id, at: Self.at("2026-11-16 09:00"))))
        let blocked = decide(world, now: "2026-11-23 09:00")
        #expect(blocked.due.isEmpty && blocked.skipped.map(\.reason) == ["The last run is still unfinished."])
        #expect(blocked.cursors[id] == Self.at("2026-11-23 09:00"))

        var done = world
        done.state.updateSignalItem(task) { $0.signalOrigin?.doneAt = Self.at("2026-11-20 10:00") }
        #expect(decide(done, now: "2026-11-23 09:00").due.map(\.signal) == [id])

        var archived = world
        let branch = try #require(archived.state.task(id: task)?.branch)
        _ = archived.state.moveToArchive(taskId: task, branch: branch, at: Self.at("2026-11-20 10:00"))
        #expect(decide(archived, now: "2026-11-23 09:00").due.map(\.signal) == [id])
    }

    @Test func aTakenOverMarkedRunDoesNotBlock() {
        var world = SignalWorld()
        let id = projectSchedule(&world)
        let task = world.markedTask(signal: id, item: .run(SignalRunRef(signal: id, at: Self.at("2026-11-16 09:00"))))
        world.state.updateSignalItem(task) { $0.takenOver = true }
        #expect(decide(world, now: "2026-11-23 09:00").due.map(\.signal) == [id])
    }

    /// A run queued or being created has no task yet, and still holds the next one back.
    @Test func aPendingRunBlocks() {
        var world = SignalWorld()
        let id = projectSchedule(&world)
        let outcome = decide(world, now: "2026-11-23 09:00", pending: [id])
        #expect(outcome.due.isEmpty && outcome.skipped.map(\.reason) == ["The last run is still unfinished."])
    }

    @Test func aProjectThatIsGoneSkipsTheFiring() {
        var (world, id) = world()
        world.state.signals[0].start.project = UUID()
        // A missing project makes the signal invalid only for the sheet; a saved signal keeps its configuration.
        let outcome = decide(world, now: "2026-11-23 09:00")
        #expect(outcome.due.isEmpty && outcome.skipped.map(\.reason) == ["Its project is no longer in AiTerm."])
        #expect(outcome.cursors[id] == Self.at("2026-11-23 09:00"))
    }

    @Test func signalsThatStartFromItemsAreLeftAlone() {
        var world = SignalWorld(); world.signal()
        let outcome = decide(world, now: "2026-11-23 09:00")
        #expect(outcome.due.isEmpty && outcome.skipped.isEmpty && outcome.cursors.isEmpty)
    }

    @Test func aRunStartsANewTaskAndNeverContinuesOne() {
        var (world, id) = world()
        let existing = world.workingTask(signal: id)
        let run = SignalRunRef(signal: id, at: Self.at("2026-11-23 09:00"))
        world.state.updateSignalTask(existing) { $0.current.item = .run(run); $0.phase = .done; $0.thenApplied = true }
        let match = SignalMatch(signal: id, item: .run(run), project: world.project.id, matchedAt: Self.at("2026-11-23 09:00"),
                                branch: world.state.task(id: existing)?.branch)
        let decisions = MatchDecision.decide(matches: [match], signals: world.state.signals, tasks: world.state.tasks,
                                             projects: world.state.projects, seen: [], complete: true)
        #expect(decisions == [.start(match, pending: [])])
        var lost = match; lost.project = nil
        #expect(MatchDecision.decide(matches: [lost], signals: world.state.signals, tasks: [], projects: world.state.projects, seen: [],
                                     complete: true) == [.skip(lost, reason: "Its project is no longer in AiTerm.")])
        #expect(ItemProjectMapper.projects(for: .run(run), in: world.state.projects, signals: world.state.signals).map(\.id) == [world.project.id])
    }

    @Test func eachRunHasABranchOfItsOwnWithItsSuffixIntact() {
        let id = UUID(uuidString: "ABCDEF12-0000-4000-8000-000000000001")!
        let long = "Update every dependency that has a minor or patch release across the whole monorepo"
        let first = BranchNaming.runBranch(signalName: long, signal: id, at: Self.at("2026-11-23 09:00"))
        let second = BranchNaming.runBranch(signalName: long, signal: id, at: Self.at("2026-11-30 09:00"))
        #expect(first == "feat/update-every-dependency-tha-abcdef-20261123-0800")
        #expect(second.hasSuffix("-abcdef-20261130-0800") && first != second)
        // The worktree directory keeps the whole suffix too.
        #expect(BranchNaming.worktreeSlug(branch: first) == "update-every-dependency-tha-abcdef-20261123-0800")
        #expect(BranchNaming.worktreeSlug(branch: first) != BranchNaming.worktreeSlug(branch: second))
        #expect(BranchNaming.runBranch(signalName: "日本語", signal: id, at: Self.at("2026-11-23 09:00"))
                == "feat/run-abcdef-20261123-0800")
    }

    @Test func twoSignalsOfOneNameFiringTogetherGetTwoBranches() {
        let a = UUID(uuidString: "11111111-0000-4000-8000-000000000001")!, b = UUID(uuidString: "22222222-0000-4000-8000-000000000001")!
        let at = Self.at("2026-11-23 09:00")
        let one = BranchNaming.runBranch(signalName: "Weekly update", signal: a, at: at)
        let two = BranchNaming.runBranch(signalName: "Weekly update!", signal: b, at: at)
        #expect(one == "feat/weekly-update-111111-20261123-0800" && two == "feat/weekly-update-222222-20261123-0800")
    }

    /// After the Mac moves from Brussels to London, its next 09:00 is another instant on the same date: another branch.
    @Test func aTimeZoneChangeNeverRepeatsABranch() {
        var london = Calendar(identifier: .gregorian); london.timeZone = TimeZone(identifier: "Europe/London")!
        let id = UUID()
        let inBrussels = Self.at("2026-11-23 09:00")
        let inLondon = london.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 9))!
        #expect(BranchNaming.runBranch(signalName: "Hourly", signal: id, at: inBrussels)
                != BranchNaming.runBranch(signalName: "Hourly", signal: id, at: inLondon))
    }

    @Test func aRunsTitleNamesItsScheduledTime() {
        #expect(ScheduleDecision.runTitle(signalName: "Weekly dependency update", at: Self.at("2026-11-23 09:00"), calendar: Self.calendar)
                == "Weekly dependency update · 23 Nov 2026 09:00")
    }

    @Test func nextRunNamesTheUpcomingTime() {
        let (world, _) = world()
        let signal = world.state.signals[0]
        #expect(ScheduleDecision.nextRun(of: signal, cursor: nil, now: Self.at("2026-11-23 09:00"), calendar: Self.calendar)
                == Self.at("2026-11-30 09:00"))
        #expect(ScheduleDecision.nextRun(of: signal, cursor: nil, now: Self.at("2026-11-23 08:00"), calendar: Self.calendar)
                == Self.at("2026-11-23 09:00"))
    }
}
