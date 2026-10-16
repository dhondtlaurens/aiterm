import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The controller's start pass under M2: as many as Agents at once allows, each claimed and on disk
/// before any window is asked for, none started twice.
@MainActor @Suite(.blocking) struct WorkerStarterClaimTests {
    func makeWorld(agentsAtOnce: Int, _ daemon: RecordingDaemon = RecordingDaemon(),
                   clock: StepClock? = nil) throws -> (OperatorWorld, OperatorRun, Project) {
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-claim-"))
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.persona(autonomy: .handsOff), projects: [project], state: .active)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]), daemon: daemon) { ports in
            ports.agentsAtOnce = { agentsAtOnce }
            if let clock { ports.now = { clock.now } }
        }
        return (world, run, project)
    }

    @Test func theCapStartsThatManyClaimedAndSavedBeforeAnyWindowIsAskedFor() async throws {
        let daemon = RecordingDaemon(holding: "window.createTask")
        let (world, run, project) = try makeWorld(agentsAtOnce: 2, daemon)
        let tasks = (1...3).map { OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-\($0)", state: .queued) }
        world.workspace.mutate { $0.tasks += tasks }
        world.controller.startReadyTasks()
        let saved = try world.workspace.file.load()
        #expect(saved.tasks.filter { $0.operated?.state == .working }.map(\.id) == [tasks[0].id, tasks[1].id], "both claims on disk")
        #expect(world.controller.starter.starting == [tasks[0].id, tasks[1].id], "starting from the claim on")
        world.controller.startReadyTasks()
        #expect(world.state.tasks.filter { $0.operated?.state == .working }.count == 2, "a second pass starts nothing more")
        #expect(await eventually(describing: "both windows asked for") { daemon.requests("window.createTask").count == 2 })
        #expect(Set(daemon.requests("window.createTask").compactMap { $0.params["taskId"] as? String })
                == [tasks[0].id.uuidString, tasks[1].id.uuidString])
        daemon.release()
        await world.controller.lastStart?.value
        #expect(await eventually(describing: "both starts to end") { world.controller.starter.starting.isEmpty })
    }

    @Test func noHelperClaimsNothing() throws {
        let (world, run, project) = try makeWorld(agentsAtOnce: 2)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-9", state: .queued)
        world.workspace.mutate { $0.tasks.append(task) }
        world.link.attached = false
        world.controller.startReadyTasks()
        #expect(world.task(task.id)?.operated?.state == .queued)
        #expect(world.controller.starter.starting.isEmpty)
    }

    @Test func aWorkspaceThatCannotSaveLaunchesNothing() throws {
        let (world, run, project) = try makeWorld(agentsAtOnce: 2)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-8", state: .queued)
        world.workspace.mutate { $0.tasks.append(task) }
        #expect(world.workspace.flush())
        try FileManager.default.createDirectory(at: world.workspace.file.backupURL, withIntermediateDirectories: true)
        world.controller.startReadyTasks()
        #expect(world.controller.starter.starting.isEmpty, "its claim taken back")
        #expect(world.task(task.id)?.operated?.state == .queued && world.task(task.id)?.operated?.launch == nil, "queued again, its slot free")
        #expect(world.daemon.requests("window.createTask").isEmpty)
    }

    /// Two tasks finishing at once, each reply running a start pass, then more passes while both launches
    /// wait on their windows: the first pass claims what the cap frees, every later one claims nothing,
    /// and no task is asked a second window — not even by the passes each launch runs as it ends.
    @Test func overlappingPassesWhileLaunchesAreHeldNeverClaimATaskTwiceNorPassTheCap() async throws {
        let daemon = RecordingDaemon(holding: "window.createTask")
        let clock = StepClock()
        let (world, run, project) = try makeWorld(agentsAtOnce: 2, daemon, clock: clock)
        let finishing = (1...2).map { OperatorServiceFixtures.task(in: run, project: project, key: "DONE-\($0)", state: .working) }
        let queued = (1...3).map { OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-\($0)", state: .queued) }
        world.workspace.mutate { $0.tasks += finishing + queued }
        world.controller.startReadyTasks()
        #expect(world.controller.starter.starting.isEmpty, "both slots held")

        world.workspace.mutate { state in for task in finishing { state.updateOperated(task.id) { $0.state = .noChange } } }
        world.controller.runChanged(run.id)
        world.controller.runChanged(run.id)
        #expect(world.controller.starter.starting == [queued[0].id, queued[1].id])
        #expect(await eventually(describing: "both launches to wait on their windows") { daemon.requests("window.createTask").count == 2 })

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
        #expect(world.state.tasks.filter { $0.operated?.state == .working }.count == 2)
        #expect(world.task(queued[2].id)?.operated?.state == .queued)

        daemon.release()
        #expect(await eventually(describing: "both launches to end") { world.controller.starter.starting.isEmpty })
        await world.controller.lastStart?.value
        #expect(daemon.requests("window.createTask").compactMap { $0.params["taskId"] as? String }.sorted()
                == [queued[0].id.uuidString, queued[1].id.uuidString].sorted(), "one window each, never a second")
        for task in queued.prefix(2) { #expect(world.task(task.id)?.operated?.launch?.number == 1) }
        #expect(Set(queued.prefix(2).compactMap { world.task($0.id)?.windowId }).count == 2, "each its own window")
        #expect(world.task(queued[2].id)?.operated?.state == .queued, "the cap still full")
    }

    /// D10's gap: a task failed and retried while its window is being asked for. No pass claims it while that
    /// launch is in flight, nor once it has ended until iTerm2 lists the window it opened — a claim then would
    /// find no worker and launch a second one. Listed, the retry goes to that worker in its own tab: one window.
    @Test func aTaskRetriedWhileItsWindowIsAskedForGetsOneWindow() async throws {
        let daemon = RecordingDaemon(holding: "window.createTask")
        let (world, run, project) = try makeWorld(agentsAtOnce: 2, daemon)
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

        world.show([OperatorServiceFixtures.session("s7", window: window, tag: task.id, state: .idle)])
        #expect(await eventually(describing: "the retry delivered to its worker") { daemon.requests("session.deliver").count == 1 })
        #expect(await eventually(describing: "the retry to settle") { world.controller.starter.starting.isEmpty })
        #expect(daemon.requests("window.createTask").count == 1, "one window, ever")
        #expect(world.task(task.id)?.operated?.state == .working)
        #expect(world.task(task.id)?.operated?.launch?.number == 2)
    }
}
