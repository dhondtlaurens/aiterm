import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor struct OperatorActivityTests {
    @Test func repeatedActionsAndTheirResultsEachHaveAnIdentity() async {
        let tracker = OperatorActivityTracker()
        var events: [OperatorActivity] = []
        tracker.changed = { events.append(tracker.event) }
        for _ in 0..<2 { await tracker.during("reading status") {} }
        #expect(events.compactMap(\.line).map(\.text) == ["reading status", "reading status"])
        #expect(Set(events.map(\.id)).count == 4)
        #expect(tracker.event.line == nil, "A result restores the current workload status.")
        #expect(tracker.event.completed?.text == "reading status", "A quick action remains available to the caption even when no frame saw its start.")
    }

    @Test func endingANestedActionRestoresTheActionStillRunning() async {
        let tracker = OperatorActivityTracker()
        await tracker.during("answering PAY-1’s worker") {
            await tracker.during("consulting the Oracle") {
                #expect(tracker.event.line?.text == "consulting the Oracle")
            }
            #expect(tracker.event.line?.text == "answering PAY-1’s worker")
        }
        #expect(tracker.event.line == nil)
    }

    /// A task's act shows while its body runs; a nested act shows until it ends, then the outer one again.
    @Test func aTasksActShowsWhileItsBodyRunsAndTheInnermostWins() async {
        let tracker = OperatorActivityTracker(), task = UUID(), other = UUID()
        var changes = 0
        tracker.changed = { changes += 1 }
        await tracker.acting(task: task, act: "consulting the Oracle") {
            #expect(tracker.act(for: task) == "consulting the Oracle" && tracker.isRunning)
            await tracker.acting(task: task, act: "answering its worker") {
                #expect(tracker.act(for: task) == "answering its worker")
                let id = tracker.begin(task: other, act: "merging it")
                #expect(tracker.latestAct == OperatorAct(task: other, words: "merging it"))
                #expect(tracker.actsByTask == [task: "answering its worker", other: "merging it"])
                tracker.end(id)
            }
            #expect(tracker.act(for: task) == "consulting the Oracle" && tracker.act(for: other) == nil)
        }
        #expect(tracker.act(for: task) == nil && tracker.latestAct == nil && !tracker.isRunning)
        #expect(changes == 6, "Each begin and end redraws the rows.")
    }

    /// A wake starts a pulse on its task, which ends by itself after `pulseLength`; a second wake restarts it.
    @Test func aWakesPulseStartsAndEndsByItself() async {
        let tracker = OperatorActivityTracker(), task = UUID()
        #expect(tracker.pulseLength == .seconds(1), "Motion.pulse, a second")
        tracker.pulseLength = .milliseconds(30)
        var changes = 0
        tracker.changed = { changes += 1 }
        tracker.woke(task: task)
        #expect(tracker.waking == [task] && changes == 1)
        await eventually(describing: "the pulse to end") { tracker.waking.isEmpty }
        #expect(changes == 2, "its end redraws the rows once")
    }

    /// A task's worker ending its turn or its stage blocking wakes the Operator with a pulse on that task; a question
    /// or a settings change wakes it with none.
    @Test func theWakerPulsesForATasksWakeOnly() throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let activity = OperatorActivityTracker()
        let log = ActivityWriter(folder: h.folder.appendingPathComponent("log"), work: OperatorWork(), now: { world.now }, activity: activity)
        let waker = OperatorWaker(workspace: h.workspace, daemon: { nil }, activity: activity, log: log, tab: { nil }, running: { true })
        waker.wake(.questionWaiting, id: id)
        waker.wake(.settingsChanged, id: id)
        #expect(activity.waking.isEmpty)
        waker.wake(.workerEnded, id: id)
        #expect(activity.waking == [id])
        let other = UUID()
        waker.wake(.taskBlocked, id: other)
        #expect(activity.waking == [id, other])
    }

    /// A launch shows "starting its worker" on the task's row while it runs and nothing once it ended. The act is
    /// not saved: a relaunch from what was saved mid-launch shows the launching stage, not an act.
    @Test func aLaunchesActIsGoneWhenItEndsAndAfterARelaunch() async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        world.state.updateSignalTask(id) { $0.phase = .launching }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let activity = OperatorActivityTracker()
        func line(_ state: AppState, acts: [UUID: String]) throws -> OperatorLine? {
            let entries = SidebarModel.entries(state: state, sessions: [], branchByCwd: [:], projectBranch: [:])
            return try #require(SignalSidebar(state: state, entries: entries, acts: acts).operatorSections.first?.tasks.first).operatorLine
        }
        var during: OperatorLine?, relaunched: OperatorLine?
        let runner = StageRunner(workspace: h.workspace, journal: h.journal, now: { world.now },
            ports: .init(workerIsWorking: { _ in false }, prepare: { task, _ in task }, launch: { _, _ in
                during = try line(h.workspace.state, acts: activity.actsByTask)
                relaunched = try line(h.file.load(), acts: [:])
                return "worker-window"
            }, restore: { $0 }), activity: activity)
        await runner.run(id)
        #expect(during == OperatorLine("Operator starting its worker", look: .acting))
        #expect(relaunched == OperatorLine("starting its worker", look: .acting), "the launching stage's own line")
        #expect(h.workspace.state.task(id: id)?.signalTask?.phase == .working)
        #expect(activity.act(for: id) == nil && !activity.isRunning)
        #expect(try line(h.workspace.state, acts: activity.actsByTask)?.text.hasPrefix("Operator") != true)
    }
}
