import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// A scheduled project signal through the controller's own tick, on a fake clock, its create and window scripted
/// (`PickupRig`): a due time is an ordinary task on a run branch, the Operator's pause does not hold it, the next time
/// waits for the last run's Done or archive, a run queued while iTerm2 is away is the only one made, and a create that
/// keeps failing is tried again three times and then skipped for good.
@Suite @MainActor struct ProjectSignalScheduleTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// The world's now is 15 Jan 2027 08:00 UTC; the schedule fires daily at 09:00.
    static let cron = "0 9 * * *"
    static func nine(_ world: SignalWorld, day: Int = 0) -> Date { world.now.addingTimeInterval(3600 + Double(day) * 86400) }

    static func scheduled(_ world: inout SignalWorld) -> UUID {
        world.projectSignal(name: "Nightly triage", start: SignalTrigger(source: .schedule, query: cron, project: world.project.id))
    }
    static func rig(_ world: SignalWorld) throws -> PickupRig {
        let rig = try PickupRig(world)
        rig.root.scheduler.calendar = { Self.calendar }
        return rig
    }
    static func tick(_ rig: PickupRig, by seconds: TimeInterval = 0) async {
        rig.clock.advance(by: seconds)
        await rig.root.reconcile(); await rig.settled()
    }
    static func runSkips(_ rig: PickupRig, _ signal: UUID) -> [SignalSeen] {
        rig.state.signalSeen.filter { $0.signal == signal && $0.disposition == .skipped }
    }

    /// At its time a project schedule makes an ordinary task: titled with the time, on the run branch from the default
    /// branch, the bare prompt, an origin naming the run, no Operator record, and its window opened behind. The moved
    /// cursor is saved, and no started record is written: a second tick in the same minute makes nothing more.
    @Test func aDueTimeMakesAnOrdinaryTaskOnARunBranch() async throws {
        var world = SignalWorld(); let signal = Self.scheduled(&world)
        let rig = try Self.rig(world); defer { rig.cleanUp() }
        await rig.start()
        await Self.tick(rig)
        #expect(rig.requests.isEmpty, "Nothing before 09:00.")

        await Self.tick(rig, by: 3600)
        let at = Self.nine(world), run = SignalRunRef(signal: signal, at: at)
        let request = try #require(rig.requests.first)
        guard case .run(let draft) = request.kind else { Issue.record("A run, not \(request.kind)."); return }
        #expect(draft.title == "Nightly triage · 15 Jan 2027 09:00")
        #expect(draft.branch == BranchNaming.runBranch(signalName: "Nightly triage", signal: signal, at: at))
        #expect(draft.baseBranch == Repository.fallbackDefaultBranch && draft.ticket == nil && !draft.appendTicket)
        #expect(request.prompt == "/psg:peer-review", "The bare prompt: a run has no description to add.")
        let task = try #require(rig.state.tasks.first)
        #expect(task.kind == .task && task.signalTask == nil && task.title == draft.title && task.branch == draft.branch)
        #expect(task.signalOrigin?.signal == signal && task.signalOrigin?.item == .run(run) && task.signalOrigin?.owed == nil)
        #expect(rig.opens.map(\.id) == [task.id] && rig.opens.first?.prompt == "/psg:peer-review")
        #expect(rig.state.signalSeen.isEmpty, "A run's cursor, not a record, keeps it from starting twice.")
        #expect(try rig.workspace.file.load().scheduleCursors[signal] == at)
        #expect(!rig.state.operatorHasWork && rig.state.operatorSession == nil)
        #expect(ProjectSignalsTests.activity(rig).isEmpty)

        await Self.tick(rig)
        #expect(rig.requests.count == 1 && rig.state.tasks.count == 1)
    }

    /// A paused Operator holds its own schedule beside, whose cursor stays for the catch-up, and not the project's.
    @Test func aPausedOperatorStopsItsOwnScheduleAndNotAProjectOne() async throws {
        var world = SignalWorld()
        let operatorSignal = world.scheduled(name: "Weekly dependency update", cron: Self.cron), signal = Self.scheduled(&world)
        world.state.operatorSession = OperatorSession(createdAt: world.now); world.state.operatorSession?.paused = true
        let rig = try Self.rig(world); defer { rig.cleanUp() }
        await rig.start()

        await Self.tick(rig, by: 3600)
        #expect(rig.state.tasks.count == 1 && rig.state.tasks.first?.signalOrigin?.signal == signal)
        #expect(rig.state.allSignalTasks.isEmpty, "The Operator's run waits for Resume.")
        #expect(rig.state.scheduleCursors[signal] == Self.nine(world) && rig.state.scheduleCursors[operatorSignal] == nil)
    }

    /// While the last run's task is in the sidebar and not done, the next time is skipped with its reason; its Done
    /// reached lets the next one run, and so does its archive (You decide's way to finish).
    @Test func theNextTimeWaitsForTheLastRunsDoneOrArchive() async throws {
        var world = SignalWorld(); let signal = Self.scheduled(&world)
        let rig = try Self.rig(world); defer { rig.cleanUp() }
        await rig.start()
        await Self.tick(rig, by: 3600)
        let first = try #require(rig.state.tasks.first?.id)

        await Self.tick(rig, by: 86400)
        #expect(rig.state.tasks.count == 1)
        #expect(Self.runSkips(rig, signal).map(\.item) == [.run(SignalRunRef(signal: signal, at: Self.nine(world, day: 1)))])
        #expect(Self.runSkips(rig, signal).first?.reason == "The last run is still unfinished.")
        #expect(rig.state.scheduleCursors[signal] == Self.nine(world, day: 1))
        #expect(ProjectSignalsTests.activity(rig).isEmpty, "A project signal's skip is not the Operator's.")

        rig.workspace.mutate { $0.updateSignalItem(first) { $0.signalOrigin?.doneAt = rig.clock.now } }
        await Self.tick(rig, by: 86400)
        #expect(rig.state.tasks.count == 2)
        let second = try #require(rig.state.tasks.first { $0.id != first })
        #expect(second.signalOrigin?.item == .run(SignalRunRef(signal: signal, at: Self.nine(world, day: 2))))

        await Self.tick(rig, by: 86400)
        #expect(rig.state.tasks.count == 2, "The second run is still unfinished.")
        rig.workspace.mutate { state in
            guard let task = state.task(id: second.id) else { return }
            state.tasks.removeAll { $0.id == second.id }
            state.archive.append(ArchivedTask(task: task, archivedAt: rig.clock.now))
        }
        await Self.tick(rig, by: 86400)
        #expect(rig.state.tasks.count == 2 && rig.state.archive.count == 1)
        #expect(rig.state.tasks.contains { $0.signalOrigin?.item == .run(SignalRunRef(signal: signal, at: Self.nine(world, day: 4))) })
    }

    /// The watch's Done for the last run, here its request merged with You decide, lets the next time run.
    @Test func aRunWhoseDoneIsReachedUnblocksTheNextRun() async throws {
        var world = SignalWorld(); let signal = Self.scheduled(&world)
        let rig = try Self.rig(world); defer { rig.cleanUp() }
        let script = DoneScript(); script.install(rig)
        await rig.start()
        await Self.tick(rig, by: 3600)
        let first = try #require(rig.state.tasks.first?.id)
        #expect(rig.state.task(id: first)?.signalOrigin?.doneKey == SignalOrigin.doneKey(SignalTrigger(source: .person, query: "")))

        script.facts.merged = true
        await Self.tick(rig, by: OperatorTiming.reconcileInterval)
        #expect(rig.state.task(id: first)?.signalOrigin?.doneAt != nil && rig.state.task(id: first)?.signalOrigin?.thenApplied == true)
        await Self.tick(rig, by: 86400 - OperatorTiming.reconcileInterval)
        #expect(rig.state.tasks.count == 2 && Self.runSkips(rig, signal).isEmpty)
    }

    /// A queued run the re-check drops, its signal switched off while iTerm2 was away, is recorded as the signal's run
    /// skip with its reason.
    @Test func aDroppedQueuedRunRecordsItsSkip() async throws {
        var world = SignalWorld(); let signal = Self.scheduled(&world)
        let rig = try Self.rig(world); defer { rig.cleanUp() }
        rig.helper = false
        await rig.start()
        await Self.tick(rig, by: 3600)
        #expect(rig.root.projectSignals.pendingRuns == [signal])

        rig.workspace.mutate { $0.signals[0].enabled = false }
        rig.helper = true
        await Self.tick(rig)
        #expect(rig.requests.isEmpty && rig.state.tasks.isEmpty && rig.root.projectSignals.pendingRuns.isEmpty)
        let skip = try #require(Self.runSkips(rig, signal).first)
        #expect(skip.item == .run(SignalRunRef(signal: signal, at: Self.nine(world))) && skip.reason == ProjectSignals.switchedOffReason)
    }

    /// A queued run whose signal was edited while iTerm2 was away so that it no longer makes this run (its project moved,
    /// or it now starts from items) is dropped and recorded as the signal's run skip: nothing is made in the old project.
    @Test(arguments: [false, true]) func aQueuedRunWhoseSignalNoLongerMakesItIsDropped(fromItems: Bool) async throws {
        var world = SignalWorld(); let signal = Self.scheduled(&world)
        let other = Project.make(name: "admin", path: "/synthetic/admin", provider: .gitlab, remoteUrl: "git@git.example:shop/admin.git")
        world.state.append(project: other)
        let rig = try Self.rig(world); defer { rig.cleanUp() }
        rig.helper = false
        await rig.start()
        await Self.tick(rig, by: 3600)
        #expect(rig.root.projectSignals.pendingRuns == [signal])

        rig.workspace.mutate { state in
            state.signals[0].start = fromItems ? SignalTrigger(source: .jira, query: "labels = review")
                : SignalTrigger(source: .schedule, query: Self.cron, project: other.id)
        }
        rig.helper = true
        await Self.tick(rig)
        #expect(rig.requests.isEmpty && rig.state.tasks.isEmpty && rig.root.projectSignals.pendingRuns.isEmpty)
        let skip = try #require(Self.runSkips(rig, signal).first)
        #expect(skip.item == .run(SignalRunRef(signal: signal, at: Self.nine(world))) && skip.reason == ProjectSignals.changedReason)
    }

    /// A run queued while iTerm2 was away whose cron is edited meanwhile (09:00 to 17:00) is a time of the old schedule:
    /// saving the edit moves `scheduledFrom` past it, so it is dropped and recorded as the signal's run skip.
    @Test func aQueuedRunWhoseCronIsEditedIsDropped() async throws {
        var world = SignalWorld(); let signal = Self.scheduled(&world)
        let rig = try Self.rig(world); defer { rig.cleanUp() }
        rig.helper = false
        await rig.start()
        await Self.tick(rig, by: 3600)
        #expect(rig.root.projectSignals.pendingRuns == [signal])

        rig.clock.advance(by: 600)
        var edited = try #require(rig.state.signal(id: signal))
        edited.start = SignalTrigger(source: .schedule, query: "0 17 * * *", project: world.project.id)
        try await rig.root.save(edited)
        #expect(rig.state.signal(id: signal)?.scheduledFrom == rig.clock.now)
        rig.helper = true
        await Self.tick(rig)
        #expect(rig.requests.isEmpty && rig.state.tasks.isEmpty && rig.root.projectSignals.pendingRuns.isEmpty)
        let skip = try #require(Self.runSkips(rig, signal).first)
        #expect(skip.item == .run(SignalRunRef(signal: signal, at: Self.nine(world))) && skip.reason == ProjectSignals.changedReason)
    }

    /// With the helper away across two times, the first run queues and holds the signal, the second is skipped as
    /// unfinished, and one task is made when iTerm2 is back: the first time's.
    @Test func withTheHelperAwayOneRunQueuesAndTheNextIsSkipped() async throws {
        var world = SignalWorld(); let signal = Self.scheduled(&world)
        let rig = try Self.rig(world); defer { rig.cleanUp() }
        rig.helper = false
        await rig.start()

        await Self.tick(rig, by: 3600)
        #expect(rig.requests.isEmpty && rig.root.projectSignals.pendingRuns == [signal])
        await Self.tick(rig, by: 86400)
        #expect(rig.requests.isEmpty)
        #expect(Self.runSkips(rig, signal).map(\.reason) == ["The last run is still unfinished."])

        rig.helper = true
        await Self.tick(rig)
        #expect(rig.requests.count == 1 && rig.state.tasks.count == 1 && rig.opens.count == 1)
        #expect(rig.state.tasks.first?.signalOrigin?.item == .run(SignalRunRef(signal: signal, at: Self.nine(world))))
        #expect(rig.root.projectSignals.pendingRuns.isEmpty)
    }

    /// A create that fails is tried again from the queue after each back-off, three times; the fourth failure skips the
    /// run for good with its reason, and the next scheduled time is a new run.
    @Test func aFailingCreateRetriesThreeTimesThenRecordsTheSkip() async throws {
        var world = SignalWorld(); let signal = Self.scheduled(&world)
        let rig = try Self.rig(world); defer { rig.cleanUp() }
        await rig.start()
        rig.failures = Array(repeating: ActionUnavailable("git refused the branch."), count: ProjectSignals.runRetries + 1)

        await Self.tick(rig, by: 3600)
        #expect(rig.requests.count == 1 && rig.state.tasks.isEmpty && Self.runSkips(rig, signal).isEmpty)
        #expect(rig.root.projectSignals.pendingRuns == [signal])
        await Self.tick(rig, by: 60)
        #expect(rig.requests.count == 1, "Backing off.")
        for retry in 1...ProjectSignals.runRetries {
            await Self.tick(rig, by: SignalPoller.failureBackOff)
            #expect(rig.requests.count == 1 + retry)
        }
        let skip = try #require(Self.runSkips(rig, signal).first)
        #expect(skip.item == .run(SignalRunRef(signal: signal, at: Self.nine(world))))
        #expect(skip.reason == "Couldn’t start its task: git refused the branch.")
        #expect(rig.root.projectSignals.pendingRuns.isEmpty && rig.state.tasks.isEmpty)

        await Self.tick(rig, by: SignalPoller.failureBackOff)
        #expect(rig.requests.count == 1 + ProjectSignals.runRetries, "Skipped for good.")
        await Self.tick(rig, by: 86400)
        #expect(rig.state.tasks.first?.signalOrigin?.item == .run(SignalRunRef(signal: signal, at: Self.nine(world, day: 1))))
    }
}
