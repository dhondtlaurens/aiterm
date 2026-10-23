import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The controller's start pass: every ready task, each claimed and on disk before any window is asked
/// for, none started twice.
@MainActor @Suite(.blocking) struct WorkerStarterClaimTests {
    func makeWorld(_ daemon: RecordingDaemon = RecordingDaemon(),
                   clock: TestClock? = nil) throws -> (OperatorWorld, OperatorRun, Project) {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-claim-"))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]), daemon: daemon) { ports in
            if let clock { ports.now = { clock.now } }
        }
        return (world, run, project)
    }

    @Test func everyReadyTaskIsClaimedAndSavedBeforeAnyWindowIsAskedFor() async throws {
        let daemon = RecordingDaemon(holding: "window.createTask")
        let (world, run, project) = try makeWorld(daemon)
        let tasks = (1...3).map { OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-\($0)", state: .queued) }
        world.workspace.mutate { $0.tasks += tasks }
        world.controller.startReadyTasks()
        let saved = try world.workspace.file.load()
        #expect(saved.tasks.filter { $0.operated?.state == .working }.map(\.id) == tasks.map(\.id), "every claim on disk")
        #expect(world.controller.starter.starting == Set(tasks.map(\.id)), "starting from the claim on")
        world.controller.startReadyTasks()
        #expect(world.state.tasks.filter { $0.operated?.state == .working }.count == 3, "a second pass starts nothing more")
        #expect(await eventually(describing: "every window asked for") { daemon.requests("window.createTask").count == 3 })
        #expect(Set(daemon.requests("window.createTask").compactMap { $0.params["taskId"] as? String })
                == Set(tasks.map(\.id.uuidString)))
        daemon.release()
        await world.controller.lastStart?.value
        #expect(await eventually(describing: "every start to end") { world.controller.starter.starting.isEmpty })
    }

    @Test func noHelperClaimsNothing() throws {
        let (world, run, project) = try makeWorld()
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-9", state: .queued)
        world.workspace.mutate { $0.tasks.append(task) }
        world.link.attached = false
        world.controller.startReadyTasks()
        #expect(world.task(task.id)?.operated?.state == .queued)
        #expect(world.controller.starter.starting.isEmpty)
    }

    @Test func aWorkspaceThatCannotSaveLaunchesNothing() throws {
        let (world, run, project) = try makeWorld()
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-8", state: .queued)
        world.workspace.mutate { $0.tasks.append(task) }
        #expect(world.workspace.flush())
        try FileManager.default.createDirectory(at: world.workspace.file.backupURL, withIntermediateDirectories: true)
        world.controller.startReadyTasks()
        #expect(world.controller.starter.starting.isEmpty, "its claim taken back")
        #expect(world.task(task.id)?.operated?.state == .queued && world.task(task.id)?.operated?.launch == nil, "queued again")
        #expect(world.daemon.requests("window.createTask").isEmpty)
    }

    /// Start passes run again and again while launches wait on their windows: the first claims everything
    /// ready, every later one claims nothing, and no task is asked a second window — not even by the
    /// passes each launch runs as it ends.
    @Test func overlappingPassesWhileLaunchesAreHeldNeverClaimATaskTwice() async throws {
        let daemon = RecordingDaemon(holding: "window.createTask")
        let clock = TestClock.operators()
        let (world, run, project) = try makeWorld(daemon, clock: clock)
        let queued = (1...3).map { OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-\($0)", state: .queued) }
        world.workspace.mutate { $0.tasks += queued }
        world.controller.startReadyTasks()
        world.controller.runChanged(run.id)
        world.controller.runChanged(run.id)
        #expect(world.controller.starter.starting == Set(queued.map(\.id)))
        #expect(await eventually(describing: "every launch to wait on its window") { daemon.requests("window.createTask").count == 3 })

        // Mid-await: a pass, reconciles over iTerm2's tabs (only the operator's listed) a minute and more apart —
        // when a claimed launch with no tab would be launched again but for `starting` — and a run change start nothing more.
        world.show([OperatorServiceFixtures.session("operator", window: "operator-window", tag: run.id)])
        world.controller.startReadyTasks()
        world.controller.reconcileTick()
        clock.advance(by: OperatorTiming.launchAdoptAfter + 1)
        world.controller.reconcileTick()
        world.controller.runChanged(run.id)
        #expect(world.run(run.id)?.state == .active, "its operator is there")
        #expect(world.controller.reconciler.lastLaunch == nil, "no relaunch of a claim whose launch is in flight")
        #expect(world.state.tasks.filter { $0.operated?.state == .working }.count == 3)

        daemon.release()
        #expect(await eventually(describing: "every launch to end") { world.controller.starter.starting.isEmpty })
        await world.controller.lastStart?.value
        #expect(daemon.requests("window.createTask").compactMap { $0.params["taskId"] as? String }.sorted()
                == queued.map(\.id.uuidString).sorted(), "one window each, never a second")
        for task in queued { #expect(world.task(task.id)?.operated?.launch?.number == 1) }
        #expect(Set(queued.compactMap { world.task($0.id)?.windowId }).count == 3, "each its own window")
    }

    /// D10's gap: a task failed and retried while its window is being asked for. No pass claims it while that
    /// launch is in flight, nor once it has ended until iTerm2 lists the window it opened — a claim then would
    /// find no worker and launch a second one. Listed, the retry goes to that worker in its own tab: one window.
    @Test func aTaskRetriedWhileItsWindowIsAskedForGetsOneWindow() async throws {
        let daemon = RecordingDaemon(holding: "window.createTask")
        let (world, run, project) = try makeWorld(daemon)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-7", state: .queued)
        world.workspace.mutate { $0.tasks.append(task) }
        world.controller.startReadyTasks()
        try await daemon.received("window.createTask")
        try world.workspace.mutate { state in
            _ = try OperatedTransitions.apply(.fail(reason: "the tests failed"), toTask: task.id, in: &state, by: .operatorTool)
            _ = try OperatedTransitions.apply(.retry, toTask: task.id, in: &state, by: .operatorTool)
        }
        #expect(world.task(task.id)?.operated?.state == .queued)
        world.controller.startReadyTasks()
        world.controller.runChanged(run.id)
        #expect(daemon.requests("window.createTask").count == 1, "its launch is in flight")

        daemon.release()
        await world.controller.lastStart?.value
        #expect(world.controller.starter.starting.isEmpty, "the first launch has settled")
        let window = try #require(world.task(task.id)?.windowId)
        world.controller.startReadyTasks()
        #expect(daemon.requests("window.createTask").count == 1, "held until iTerm2 lists the window it opened")
        #expect(world.task(task.id)?.operated?.state == .queued)

        // Listed first as the shell the agent command is typed into: no worker there yet, so still held.
        world.show([OperatorServiceFixtures.session("s7", window: window, tag: task.id, agent: .shell, state: .idle)])
        world.controller.startReadyTasks()
        #expect(world.task(task.id)?.operated?.state == .queued, "a shell is not its worker")
        #expect(daemon.requests("window.createTask").count == 1 && daemon.requests("session.deliver").isEmpty)

        world.show([OperatorServiceFixtures.session("s7", window: window, tag: task.id, agent: .claude, state: .idle)])
        #expect(await eventually(describing: "the retry delivered to its worker") { daemon.requests("session.deliver").count == 1 })
        #expect(await eventually(describing: "the retry to settle") { world.controller.starter.starting.isEmpty })
        #expect(daemon.requests("window.createTask").count == 1, "one window, ever")
        #expect(world.task(task.id)?.operated?.state == .working)
        #expect(world.task(task.id)?.operated?.launch?.number == 2)
        #expect(daemon.requests("session.deliver").count == 1, "delivered once")
        #expect(daemon.requests("session.deliver").first?.params["sessionId"] as? String == "s7")
    }
}
