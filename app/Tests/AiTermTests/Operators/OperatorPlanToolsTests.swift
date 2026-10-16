import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The plan (spec §6, §8): unstarted tasks added and changed in the open revision, a revision
/// submitted once, queued at once when ungated and on your approval of that exact revision when gated.
@MainActor @Suite struct OperatorPlanToolsTests {
    let project = OperatorServiceFixtures.project(), other = OperatorServiceFixtures.project(path: "/tmp/aiterm-operators-other", name: "Web")
    let docs = OperatorServiceFixtures.project(path: "/tmp/aiterm-operators-docs", name: "Docs")

    /// The plan tools need no helper, and without one nothing a released task starts (D10's
    /// `WorkerStarter.start` returns nil), so a queued task stays queued for the test to read. M1's
    /// rules by name: F1 and G6 raise `OperatorMilestone.current`.
    func makeWorld(_ autonomy: Autonomy) throws -> (OperatorWorld, OperatorRun) {
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.persona(autonomy: autonomy), projects: [project, other])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project, other, docs], runs: [run])) { $0.milestone = .m1 }
        world.link.attached = false
        return (world, run)
    }

    func create(_ world: OperatorWorld, _ run: OperatorRun, _ key: String, project: String = "Shop", end: String = "commit",
                dependsOn: JSONValue = []) async -> ToolAnswer {
        await world.call(run.id, "create_task", ["key": .string(key), "title": .string("Fix \(key)"), "brief": .string("Fix \(key) and test it."),
                                                 "project": .string(project), "ticket": .string(key), "agent": "codex", "model": "gpt-6-astra",
                                                 "end": .string(end), "dependsOn": dependsOn])
    }

    func operated(_ world: OperatorWorld, _ key: String) -> OperatedTask? {
        world.state.tasks.compactMap(\.operated).first { $0.key == key }
    }

    @Test func createTaskAddsOnePlannedRowWithoutAWorktreePerKey() async throws {
        let (world, run) = try makeWorld(.routine)
        let first = await create(world, run, "PLUTO-231"), again = await create(world, run, "PLUTO-231")
        #expect(first.value?["created"] == true && again.value?["created"] == false)
        #expect(first.value?["task"] == again.value?["task"])
        let task = try #require(world.state.tasks.only)
        #expect(task.worktreePath.isEmpty && task.windowId == nil && task.projectId == project.id)
        #expect(task.agent == .codex && task.model == "gpt-6-astra" && task.firstPrompt == "Fix PLUTO-231 and test it.")
        #expect(task.jira?.key == "PLUTO-231")
        #expect(task.operated?.state == .planned && task.operated?.revision == 1 && task.operated?.end == .commit)
    }

    @Test func aTaskOutsideTheOperationsProjectsOrAgentsIsRefusedWhenGated() async throws {
        let (world, run) = try makeWorld(.routine)
        #expect(await create(world, run, "A", project: "Elsewhere").message == "AiTerm has no project called Elsewhere. This operation’s projects are: Shop, Web.")
        #expect(await create(world, run, "A", project: "Docs").message
                == "Docs isn’t one of this operation’s projects: Shop, Web. Adding a project needs the person’s approval: ask_you first.")
        let grok = await world.call(run.id, "create_task", ["key": "B", "title": "B", "brief": "b", "project": "Shop", "agent": "grok", "model": "m"])
        #expect(grok.message == "An operator’s task runs claude or codex.")
        #expect(world.state.tasks.isEmpty)
    }

    @Test func anUngatedOperationTakesInAnotherProjectOfTheWorkspace() async throws {
        let (world, run) = try makeWorld(.trusted)
        #expect(await create(world, run, "A", project: "Docs").value?["created"] == true)
        #expect(world.run(run.id)?.projectIds == [project.id, other.id, docs.id])
    }

    @Test func aTaskStacksOnAtMostOneCodeParentInItsOwnProject() async throws {
        let (world, run) = try makeWorld(.routine)
        _ = await create(world, run, "A")
        _ = await create(world, run, "B")
        _ = await create(world, run, "W", project: "Web")
        let two = await create(world, run, "C", dependsOn: [["task": "A", "kind": "code"], ["task": "B", "kind": "code"]])
        #expect(two.message == "A task stacks on at most one code dependency: its worktree branches from one parent.")
        let across = await create(world, run, "D", dependsOn: [["task": "W", "kind": "code"]])
        #expect(across.message == "A code dependency stays in one project: W is in Web.")
        _ = await create(world, run, "E", dependsOn: [["task": "A", "kind": "code"], "B"])
        let stacked = try #require(operated(world, "E"))
        let a = try #require(world.state.tasks.first { $0.operated?.key == "A" }), b = try #require(world.state.tasks.first { $0.operated?.key == "B" })
        #expect(stacked.stackedOn == a.id)
        #expect(stacked.dependsOn == [TaskDependency(task: a.id, kind: .code), TaskDependency(task: b.id, kind: .order)])
    }

    @Test func anUngatedPlanIsQueuedOnSubmitAndSubmittingItAgainChangesNothing() async throws {
        let (world, run) = try makeWorld(.handsOff)
        _ = await create(world, run, "A")
        let submitted = await world.call(run.id, "submit_plan", ["revision": 1])
        #expect(submitted.value?["waitingForApproval"] == false && submitted.value?["openRevision"] == 2 && submitted.value?["released"] == 1)
        #expect(operated(world, "A")?.state == .queued)
        #expect(world.run(run.id)?.state == .active && world.run(run.id)?.planRevision == 1)
        let saved = world.state
        let again = await world.call(run.id, "submit_plan", ["revision": 1])
        #expect(again.value?["repeated"] == true && again.value?["revision"] == 1)
        // A repeat did not release anything now, but it must not read as "nothing was released" either.
        #expect(again.value?["released"] == nil && again.value?["note"]?.stringValue?.contains("already submitted") == true)
        #expect(world.state == saved)
        #expect(await world.call(run.id, "submit_plan", ["revision": 5]).message == PlanRevision.Failure.unknownRevision(open: 2, asked: 5).description)
    }

    @Test func aGatedPlanWaitsForYourApprovalOfThatExactRevision() async throws {
        let (world, run) = try makeWorld(.routine)
        _ = await create(world, run, "A")
        #expect(await world.call(run.id, "submit_plan", ["revision": 1]).value?["waitingForApproval"] == true)
        #expect(operated(world, "A")?.state == .planned && world.run(run.id)?.state == .planning)
        #expect(world.notifications.posted.map(\.target) == [.overview(run.id)])
        try world.controller.approvePlan(run: run.id, revision: 1)
        #expect(operated(world, "A")?.state == .queued && world.run(run.id)?.state == .active && world.run(run.id)?.approvedRevision == 1)
        _ = await create(world, run, "B")
        _ = await world.call(run.id, "submit_plan", ["revision": 2])
        #expect(throws: ActionUnavailable.self) { try world.controller.approvePlan(run: run.id, revision: 1) }
        #expect(operated(world, "B")?.state == .planned)
        try world.controller.approvePlan(run: run.id, revision: 2)
        #expect(operated(world, "B")?.state == .queued)
    }

    @Test func m1RefusesAPlanThatEndsBeyondACommitWithTheReason() async throws {
        let (world, run) = try makeWorld(.handsOff)
        _ = await create(world, run, "A", end: "merge")
        let refused = await world.call(run.id, "submit_plan", ["revision": 1])
        #expect(refused.message == PlanRevision.Failure.unsupportedEnd(key: "A", .merge).description)
        #expect(world.run(run.id)?.planRevision == 0 && operated(world, "A")?.state == .planned)
        _ = await world.call(run.id, "update_task", ["task": "A", "end": "commit"])
        #expect(await world.call(run.id, "submit_plan", ["revision": 1]).value?["submitted"] == true)
    }

    @Test func updateTaskChangesOnlyAnUnstartedTask() async throws {
        let (world, run) = try makeWorld(.routine)
        _ = await create(world, run, "A")
        _ = await world.call(run.id, "update_task", ["task": "A", "brief": "Fix A, then document it."])
        #expect(operated(world, "A")?.brief == "Fix A, then document it.")
        #expect(world.state.tasks.first?.firstPrompt == "Fix A, then document it.")
        let id = try #require(world.state.tasks.first?.id)
        world.workspace.mutate { $0.updateOperated(id) { $0.state = .working } }
        #expect(await world.call(run.id, "update_task", ["task": "A", "brief": "x"]).message
                == "A has started: steer it with message_task, and log the steer with log_decision.")
    }

    @Test func switchingAnUnstartedTasksAgentTakesTheNewAgentsModelNotTheOldOnes() async throws {
        let (world, run) = try makeWorld(.routine)
        world.workspace.mutate { $0.lastModelByAgent[.claude] = "claude-remembered" }
        // What Settings › Agents (or the remembered model) gives claude: the fallback create_task uses too.
        let fallback = AgentIntegrations.fixerModels(remembered: world.state.lastModelByAgent)(.claude)
        try #require(!fallback.model.isEmpty)
        _ = await create(world, run, "A")
        world.workspace.mutate { $0.tasks[0].reasoning = "old-agents-reasoning" }
        let switched = await world.call(run.id, "update_task", ["task": "A", "agent": "claude"])
        #expect(switched.value?["created"] == false, "\(switched)")
        var task = try #require(world.state.tasks.first)
        #expect(task.agent == .claude && task.model == fallback.model && task.reasoning == fallback.reasoning)
        #expect(task.model != "gpt-6-astra" && task.reasoning != "old-agents-reasoning")
        // A model named with the new agent is the one it gets; the same agent with no model keeps its own.
        _ = await world.call(run.id, "update_task", ["task": "A", "agent": "claude", "model": "claude-named"])
        _ = await world.call(run.id, "update_task", ["task": "A", "agent": "claude"])
        task = try #require(world.state.tasks.first)
        #expect(task.agent == .claude && task.model == "claude-named" && task.reasoning == nil)
        _ = await world.call(run.id, "update_task", ["task": "A", "model": "claude-other"])
        #expect(world.state.tasks.first?.model == "claude-other")
    }

    @Test func aRefusedCreateTaskLeavesTheOperationsProjectsAsTheyWere() async throws {
        let (world, run) = try makeWorld(.trusted)
        let refused = await world.call(run.id, "create_task", ["key": "A", "title": "A", "brief": "a", "project": "Docs", "agent": "grok", "model": "m"])
        #expect(refused.message == "An operator’s task runs claude or codex.")
        #expect(world.run(run.id)?.projectIds == [project.id, other.id] && world.state.tasks.isEmpty)
        #expect(await create(world, run, "B", project: "Docs", end: "nonsense").message == "A task’s end is commit, draftMR or merge.")
        #expect(world.run(run.id)?.projectIds == [project.id, other.id])
        #expect(await create(world, run, "C", project: "Docs").value?["created"] == true)
        #expect(world.run(run.id)?.projectIds == [project.id, other.id, docs.id])
        // A second task in it does not list it twice.
        _ = await create(world, run, "D", project: "Docs")
        #expect(world.run(run.id)?.projectIds == [project.id, other.id, docs.id])
    }

    @Test func approvingAnApprovedRevisionAgainWakesTheOperatorOnlyOnce() async throws {
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.persona(autonomy: .routine), projects: [project, other])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project, other], runs: [run])) {
            $0.milestone = .m1
            $0.wakeCoalesce = .zero
        }
        world.show([OperatorServiceFixtures.session("op", tag: run.id)])
        _ = await create(world, run, "A")
        _ = await world.call(run.id, "submit_plan", ["revision": 1])
        func wakes() -> [String] { world.daemon.requests("session.deliver").compactMap { $0.params["text"] as? String } }
        try world.controller.approvePlan(run: run.id, revision: 1)
        try await world.daemon.received("session.deliver")
        await world.controller.waker.lastSend?.value
        #expect(wakes() == ["[AiTerm] plan approved — call run_status"])
        try world.controller.approvePlan(run: run.id, revision: 1)
        // Nothing was armed, so nothing arrives; a settled wait is all an absence can be checked with.
        try await Task.sleep(for: .milliseconds(100))
        #expect(wakes().count == 1 && world.run(run.id)?.approvedRevision == 1)
    }
}

private extension Array {
    /// The one element, or nil when there are none or several.
    var only: Element? { count == 1 ? first : nil }
}
