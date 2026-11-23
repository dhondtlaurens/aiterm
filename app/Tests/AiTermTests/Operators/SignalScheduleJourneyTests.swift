import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// A scheduled signal through the controller's own entry points, on a fake clock: a firing starts a run in its project
/// on a branch of its own, a firing while that run works is skipped, and after two missed Mondays only the latest runs.
@MainActor @Suite(.blocking) struct SignalScheduleJourneyTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Brussels")!
        return calendar
    }()
    static func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    @Test func aScheduleStartsARunSkipsWhileItWorksAndCatchesUpOnce() async throws {
        let fixture = try await RaceFixture()
        let daemon = RecordingDaemon()
        fixture.controller.helper.setDaemonClient(daemon)
        // Monday 23 Nov 2026, a minute before the schedule's 09:00.
        let clock = TestClock(Self.at(2026, 11, 23, 8, 59))
        var ports = OperatorPorts.scratch()
        ports.clock.now = { clock.now }
        let workspace = fixture.controller.workspace
        let signal = Signal(name: "Weekly dependency update", createdAt: clock.now,
                            start: SignalTrigger(source: .schedule, query: "0 9 * * 1", project: fixture.project.id),
                            done: SignalTrigger(source: .operator, query: ""),
                            work: SignalWork(prompt: "Update the dependencies", ticketDescription: false, requestDescription: false),
                            agents: [SignalWorld.agent], finish: SignalFinish(then: .keep), scheduledFrom: clock.now)
        workspace.mutate { $0.signals.append(signal) }
        #expect(workspace.flush())

        let controller = SignalOperatorController(workspace: workspace, live: fixture.controller.live, work: fixture.controller.work,
                                                  ports: ports, daemon: { daemon }, frame: { Frame(x: 0, y: 0, w: 400, h: 400) },
                                                  automatic: false)
        controller.archive = fixture.controller.signalController.archive
        controller.checkout = fixture.controller.signalController.checkout
        controller.restore = fixture.controller.signalController.restore
        controller.scheduler.calendar = { Self.calendar }
        fixture.controller.helper.onEvent { [weak controller] in controller?.handle($0) }
        defer {
            controller.stop()
            fixture.controller.shutdown()
            fixture.cleanUp()
            try? FileManager.default.removeItem(at: ports.home)
        }

        // Act 1: nothing before 09:00; at 09:00 one run in the signal's project.
        controller.start()
        fixture.controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [], usage: .empty)))
        await ports.work.settled()
        #expect(workspace.state.tasks.isEmpty)

        clock.advance(by: 61)
        await controller.reconcile()
        await ports.work.settled()
        let first = Self.at(2026, 11, 23, 9, 0)
        #expect(workspace.state.tasks.count == 1)
        let task = try #require(workspace.state.tasks.first)
        #expect(task.projectId == fixture.project.id)
        #expect(task.title == "Weekly dependency update · 23 Nov 2026 09:00")
        #expect(task.branch == BranchNaming.runBranch(signalName: signal.name, signal: signal.id, at: first))
        #expect(task.signalTask?.current.item == .run(SignalRunRef(signal: signal.id, at: first)))
        #expect(task.signalTask?.scheduledRun == SignalRunRef(signal: signal.id, at: first))
        #expect(task.signalTask?.phase == .working)
        #expect(task.signalTask?.doneMatched == false, "an Operator Done's baseline never matches")
        #expect(FileManager.default.fileExists(atPath: task.worktreePath))
        #expect(task.firstPrompt == nil || task.firstPrompt?.contains("untrusted item descriptions") == false)
        #expect(try fixture.controller.savedWorkspace().scheduleCursors[signal.id] == first, "the cursor is saved with the task")

        // A second tick in the same minute starts nothing more.
        await controller.reconcile()
        await ports.work.settled()
        #expect(workspace.state.tasks.count == 1)

        // Act 2: the next Monday, while that run still works, is skipped with its reason.
        clock.advance(by: 7 * 86400)
        await controller.reconcile()
        await ports.work.settled()
        #expect(workspace.state.tasks.count == 1)
        let second = Self.at(2026, 11, 30, 9, 0)
        #expect(workspace.state.scheduleCursors[signal.id] == second)
        let skips = workspace.state.signalSeen.filter { $0.signal == signal.id && $0.disposition == .skipped }
        #expect(skips.map(\.item) == [.run(SignalRunRef(signal: signal.id, at: second))])
        #expect(skips.first?.reason == "The last run is still unfinished.")

        // Act 3: the run is finished; AiTerm is away through two Mondays, and only the latest runs.
        workspace.mutate { state in state.updateSignalTask(task.id) { $0.phase = .done; $0.thenApplied = true } }
        #expect(workspace.flush())
        clock.advance(by: 14 * 86400 + 3600)
        await controller.reconcile()
        await ports.work.settled()
        let latest = Self.at(2026, 12, 14, 9, 0)
        #expect(workspace.state.tasks.count == 2)
        let run = try #require(workspace.state.tasks.first { $0.id != task.id })
        #expect(run.signalTask?.scheduledRun?.at == latest)
        #expect(run.title == "Weekly dependency update · 14 Dec 2026 09:00")
        #expect(run.branch != task.branch)
        #expect(workspace.state.scheduleCursors[signal.id] == latest)
    }

    @Test func savingSetsScheduledFromOnCreateSwitchOnAndCronEdits() {
        let now = Self.at(2026, 11, 23, 10, 0), earlier = Self.at(2026, 11, 1, 10, 0)
        var signal = Signal(name: "Weekly", createdAt: earlier,
                            start: SignalTrigger(source: .schedule, query: "0 9 * * 1", project: UUID()),
                            done: SignalTrigger(source: .operator, query: ""), work: SignalWork(prompt: "Go"),
                            agents: [SignalWorld.agent], finish: SignalFinish(), scheduledFrom: earlier)
        #expect(SignalOperatorController.scheduledFrom(signal, saved: nil, now: now) == now)
        #expect(SignalOperatorController.scheduledFrom(signal, saved: signal, now: now) == earlier)
        var off = signal; off.enabled = false
        #expect(SignalOperatorController.scheduledFrom(signal, saved: off, now: now) == now, "switched on")
        #expect(SignalOperatorController.scheduledFrom(off, saved: signal, now: now) == earlier, "switched off keeps it")
        var edited = signal; edited.start.query = "0 10 * * 1"
        #expect(SignalOperatorController.scheduledFrom(edited, saved: signal, now: now) == now)
        var renamed = signal; renamed.name = "Weekly update"
        #expect(SignalOperatorController.scheduledFrom(renamed, saved: signal, now: now) == earlier)
        signal.start = SignalTrigger(source: .jira, query: "labels = operator")
        #expect(SignalOperatorController.scheduledFrom(signal, saved: nil, now: now) == nil)
    }
}
