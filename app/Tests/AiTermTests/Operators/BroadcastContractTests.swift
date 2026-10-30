import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// What a broadcast set up with Agents, Task and Done is started with and answered by, before each step is built: the
/// steps frozen in the run, the last broadcast's rows, the two new tools registered and refused, write_summary waiting on
/// a due goal check, ask_you's `about`, the hook a run's change is told to, and what New Broadcast opens with.
@MainActor @Suite struct BroadcastContractTests {
    let project = OperatorServiceFixtures.project()

    private func start(_ world: OperatorWorld, agents: [AgentChoice] = OperatorServiceFixtures.agents,
                       taskSettings: TaskSettings = OperatorServiceFixtures.taskSettings,
                       goal: BroadcastGoal? = OperatorServiceFixtures.goal) async throws -> OperatorRun {
        let id = try await world.controller.startBroadcast(name: nil, jiraProjectKeys: [], projectIds: [project.id], prompt: "Go.",
                                                           agents: agents, taskSettings: taskSettings,
                                                           goal: goal)
        return try #require(world.run(id))
    }

    /// Started with the steps, the run freezes them, its goal's words trimmed, and keeps no Review or Done text; its rows
    /// become the last broadcast's.
    @Test func aStartFreezesTheStepsAndSavesItsRowsAsTheLast() async throws {
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [])) {
            $0.profile = { OperatorServiceFixtures.profile(oracle: true) }
        }
        let goal = OperatorServiceFixtures.goal
        let run = try await start(world, goal: BroadcastGoal(text: "\n  \(goal.text)  \n", extraRounds: goal.extraRounds))
        #expect(run.agents == OperatorServiceFixtures.agents && run.taskSettings == OperatorServiceFixtures.taskSettings)
        #expect(run.goal == goal)
        #expect(OperatorProfileStore.lastAgents(try #require(world.ports.preferences)) == OperatorServiceFixtures.agents)
        #expect(try world.workspace.file.load().runs.first?.taskSettings == OperatorServiceFixtures.taskSettings, "frozen on disk")
    }

    /// A goal needs the Oracle: with it off, or with no words, the broadcast starts without one.
    @Test func aGoalNeedsTheOracleAndWords() async throws {
        let off = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: []))
        #expect(try await start(off).goal == nil)
        let blank = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [])) {
            $0.profile = { OperatorServiceFixtures.profile(oracle: true) }
        }
        #expect(try await start(blank, goal: BroadcastGoal(text: "  ")).goal == nil)
    }



    @Test func theLastRowsAreNoneUntilSaved() throws {
        let preferences = ScratchDefaults.make()
        #expect(OperatorProfileStore.lastAgents(preferences).isEmpty)
        preferences.set(Data("not rows".utf8), forKey: OperatorProfileStore.lastAgentsKey)
        #expect(OperatorProfileStore.lastAgents(preferences).isEmpty, "what can't be read is none")
    }

    /// Both new tools change the run; recording a review is not challenged and must name a task in the run.
    @Test func recordReviewAndCheckGoalAreMutating() async throws {
        #expect(OperatorToolHandler.mutating.isSuperset(of: [.recordReview, .checkGoal]))
        #expect(!OperatorToolHandler.isChallenged(ToolCall(tool: "record_review", arguments: [:]), oracleIsOn: true))
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        #expect(await world.call(run.id, "record_review", ["task": "A"]).message == "No task A in this broadcast.")
    }

    /// With the Oracle on, check_goal is its veto; while no goal check is due it costs no Oracle run.
    @Test func checkGoalIsTheOraclesVetoOnlyOnceACheckIsDue() async throws {
        func call(_ arguments: JSONValue) -> ToolCall { ToolCall(tool: "check_goal", arguments: arguments) }
        #expect(OperatorToolHandler.isChallenged(call(["met": true]), oracleIsOn: true))
        #expect(!OperatorToolHandler.isChallenged(call(["met": true]), oracleIsOn: false))

        let prompts = OperatorMergeTests.Prompts()
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.profile(oracle: true, oracleAgent: .claude), projects: [project], state: .active,
                                              planRevision: 1, goal: OperatorServiceFixtures.goal)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) {
            $0.secondOpinion = .answering("YES", receivePrompt: { prompts.append($0) })
            $0.challengeReplyBudget = .seconds(60)
        }
        #expect(await world.call(run.id, "check_goal", ["met": true, "evidence": "All shipped."]).message
                == "No goal check is due: AiTerm wakes you for it once every task is done.")
        #expect(prompts.list.isEmpty, "no goal check is due")

        world.workspace.mutate { $0.updateRun(id: run.id) { $0.goalCheckDue = true } }
        _ = await world.call(run.id, "check_goal", ["met": true, "evidence": "All shipped."])
        #expect(prompts.list.count == 1 && prompts.list.first?.contains("check_goal with") == true)
    }

    @Test func writeSummaryIsRefusedWhileTheGoalIsStillToCheck() async throws {
        var run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1, goal: OperatorServiceFixtures.goal)
        run.goalCheckDue = true
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        #expect(await world.call(run.id, "write_summary", ["text": "Done."]).message
                == "Every task is done but the goal is still to check: call check_goal first.")
        #expect(world.run(run.id)?.summary == nil)
    }

    /// ask_you keeps what its question is about, `fixRounds` alone for now.
    @Test func askYouKeepsWhatItIsAbout() async throws {
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "A", state: .working)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]))
        _ = await world.call(run.id, "ask_you", ["key": "rounds-A", "question": "A is out of fix rounds.", "task": "A", "about": "fixRounds"])
        #expect(world.run(run.id)?.questions.first?.about == OperatorQuestion.fixRounds)
        _ = await world.call(run.id, "ask_you", ["key": "plain", "question": "Which locale?"])
        #expect(world.run(run.id)?.questions.last?.about == nil)
        #expect(await world.call(run.id, "ask_you", ["key": "odd", "question": "?", "about": "lunch"]).message
                == "about is fixRounds, or left out.")
    }

    /// Each change to a run is told to the hook, after it was settled.
    @Test func aRunsChangeIsToldToTheHook() throws {
        let run = OperatorServiceFixtures.run(projects: [project], state: .active, planRevision: 1)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        var told: [UUID] = []
        world.controller.onRunChanged = { told.append($0) }
        world.controller.runChanged(run.id)
        #expect(told == [run.id])
    }

    /// New Broadcast opens with the installed agents' models, their Settings › Agents defaults, the profile's slices and
    /// Oracle, and the last broadcast's rows.
    @Test func newBroadcastOpensWithItsContext() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var ports = OperatorPorts.scratch()
        var profile = OperatorServiceFixtures.profile(oracle: true)
        profile.slices = Slices(merge: true)
        let frozen = profile
        ports.profile = { frozen }
        try OperatorProfileStore.saveLastAgents(OperatorServiceFixtures.agents, try #require(ports.preferences))
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch(),
                                       operatorPorts: ports)
        try controller.workspace.load()
        controller.presentNewBroadcast()
        #expect(await eventually(describing: "New Broadcast opens") { controller.sheet != nil })
        guard case .newBroadcast(let sheet)? = controller.sheet else { Issue.record("no New Broadcast sheet"); return }
        #expect(sheet.context.slices == Slices(merge: true) && sheet.context.oracleIsOn)
        #expect(sheet.context.lastAgents == OperatorServiceFixtures.agents)
        #expect(sheet.context.models == [.claude: OperatorServiceFixtures.models[.claude]!, .codex: OperatorServiceFixtures.models[.codex]!])
        #expect(sheet.context.defaults[.codex] == AgentChoice(agent: .codex, model: "gpt-6-astra", reasoning: "medium"),
                "no default saved: the first model the list has, at its default reasoning")
    }
}
