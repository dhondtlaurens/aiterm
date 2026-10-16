import Testing
import Foundation
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

/// Settings › Agents' "Agents at once", as `AgentIntegrations` keeps it and the group words it.
@MainActor @Suite(.blocking) struct AgentsAtOnceTests {
    private func integrations(_ defaults: UserDefaults) -> AgentIntegrations {
        AgentIntegrations(harnessHome: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                          bundledResourcesURL: nil, locateAgents: { nil }, rememberedModels: { [:] }, defaults: defaults)
    }

    @Test func theCountIsSavedOnEveryChangeAndReadAtTheNextLaunch() {
        let defaults = ScratchDefaults.make()
        let first = integrations(defaults)
        #expect(first.agentsAtOnce == 2)
        var told = 0
        first.agentsAtOnceChanged = { told += 1 }
        first.agentsAtOnce = 4
        first.agentsAtOnce = 4
        #expect(told == 1, "an equal write is no change")
        #expect(OperatorSettings.agentsAtOnce(defaults: defaults) == 4)
        #expect(integrations(defaults).agentsAtOnce == 4)
    }

    /// The setting reaches the operators: a raised cap runs a start pass, which starts the next queued task.
    @Test func raisingTheCountStartsTheNextQueuedTask() async throws {
        let preferences = InterfacePreferences.scratch()
        var ports = OperatorPorts.scratch()
        ports.agentsAtOnce = { OperatorSettings.agentsAtOnce(defaults: preferences.defaults) }
        let controller = AppController(preferences: preferences, operatorPorts: ports)
        defer { controller.shutdown() }
        try controller.loadWorkspace()
        let project = OperatorServiceFixtures.project(path: try GitFixture.makeRepo(prefix: "op-cap-"))
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.persona(autonomy: .handsOff), projects: [project], state: .active)
        let tasks = (1...2).map { OperatorServiceFixtures.task(in: run, project: project, key: "PLUTO-\($0)", state: .queued) }
        controller.workspace.mutate { state in
            state.append(project: project)
            state.runs = [run]
            state.tasks = tasks
        }
        let daemon = RecordingDaemon()
        controller.helper.setDaemonClient(daemon)
        controller.agents.agentsAtOnce = 1
        #expect(await eventually(describing: "one window at a cap of one") { daemon.requests("window.createTask").count == 1 })
        #expect(controller.state.task(id: tasks[1].id)?.operated?.state == .queued)
        controller.agents.agentsAtOnce = 2
        #expect(controller.state.task(id: tasks[1].id)?.operated?.state == .working, "the raised cap started it at once")
        #expect(await eventually(describing: "its window asked for") { daemon.requests("window.createTask").count == 2 })
    }

    @Test func theHelpSaysWhatTheCountDoes() {
        #expect(AgentsAtOnceGroup.help(1) == "Operators start one agent at a time, across every operation, each in its own worktree and window. Lowering it stops no agent that is running.")
        #expect(AgentsAtOnceGroup.help(3) == "Operators run up to 3 agents at once, across every operation, each in its own worktree and window. Lowering it stops no agent that is running.")
    }

    @Test func theImageIsDrawnLastInTheSettingsSetAndTheSameTwice() throws {
        let snapshot = try #require(SettingsSnapshots.all.last)
        #expect(snapshot.file == "settings-agents-at-once.png")
        let first = try #require(Snapshots.png(of: snapshot), "\(snapshot.file) drew nothing")
        let second = try #require(Snapshots.png(of: snapshot))
        #expect(first.count > 1_000, "\(snapshot.file) is empty")
        #expect(first == second, "\(snapshot.file) is not drawn the same twice")
    }
}
