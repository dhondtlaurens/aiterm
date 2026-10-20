import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The plan (spec §6, §8): unstarted tasks added and changed in the open revision, a revision
/// submitted once, and queued at once when it is.
@MainActor @Suite struct OperatorPlanToolsTests {
    let project = OperatorServiceFixtures.project(), other = OperatorServiceFixtures.project(path: "/tmp/aiterm-operators-other", name: "Web")
    let docs = OperatorServiceFixtures.project(path: "/tmp/aiterm-operators-docs", name: "Docs")

    /// The plan tools need no helper, and without one nothing a released task starts (D10's
    /// `WorkerStarter.start` returns nil), so a queued task stays queued for the test to read. M1's
    /// rules by name unless a test asks for another milestone: F1 and G6 raised `OperatorMilestone.current`.
    func makeWorld(milestone: OperatorMilestone = .m1) throws -> (OperatorWorld, OperatorRun) {
        let run = OperatorServiceFixtures.run(projects: [project, other])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project, other, docs], runs: [run])) { $0.milestone = milestone }
        world.link.attached = false
        return (world, run)
    }

    func create(_ world: OperatorWorld, _ run: OperatorRun, _ key: String, project: String = "Shop", end: String = "commit",
                dependsOn: JSONValue = [], challengeId: String? = nil) async -> ToolAnswer {
        var arguments: [String: JSONValue] = ["key": .string(key), "title": .string("Fix \(key)"), "brief": .string("Fix \(key) and test it."),
                                              "project": .string(project), "ticket": .string(key), "agent": "codex", "model": "gpt-6-astra",
                                              "modelReason": "Codex reads the parser best.", "end": .string(end), "dependsOn": dependsOn]
        if let challengeId { arguments["challengeId"] = .string(challengeId) }
        return await world.call(run.id, "create_task", .object(arguments))
    }

    func operated(_ world: OperatorWorld, _ key: String) -> OperatedTask? {
        world.state.tasks.compactMap(\.operated).first { $0.key == key }
    }

    @Test func createTaskAddsOnePlannedRowWithoutAWorktreePerKey() async throws {
        let (world, run) = try makeWorld()
        let first = await create(world, run, "PLUTO-231"), again = await create(world, run, "PLUTO-231")
        #expect(first.value?["created"] == true && again.value?["created"] == false)
        #expect(first.value?["task"] == again.value?["task"])
        let task = try #require(world.state.tasks.only)
        #expect(task.worktreePath.isEmpty && task.windowId == nil && task.projectId == project.id)
        #expect(task.agent == .codex && task.model == "gpt-6-astra" && task.firstPrompt == "Fix PLUTO-231 and test it.")
        #expect(task.jira?.key == "PLUTO-231")
        #expect(task.operated?.state == .planned && task.operated?.revision == 1 && task.operated?.end == .commit)
        #expect(task.reasoning == "medium", "a named model takes its own default effort")
        #expect(task.operated?.modelReason == "Codex reads the parser best." && task.operated?.agentPinned == false)
    }

    @Test func aPinnedAgentAndTheModelsReasonAreKeptOnTheTask() async throws {
        let (world, run) = try makeWorld()
        _ = await world.call(run.id, "create_task", ["key": "A", "title": "A", "brief": "a", "project": "Shop", "agent": "claude",
                                                     "model": "claude-named", "modelReason": "The prompt says Claude.", "agentPinned": true])
        let operated = try #require(operated(world, "A"))
        #expect(operated.agentPinned && operated.modelReason == "The prompt says Claude.")
        #expect(await world.call(run.id, "create_task", ["key": "B", "title": "B", "brief": "b", "project": "Shop", "agent": "claude"])
                .message == "create_task needs `modelReason`.")
    }

    /// Spec §15: only a model in the agent's own list in Settings › Agents; the refusal names that list.
    /// A task whose agent can't be messaged can't be steered or get review fixes: create_task refuses it while
    /// another installed agent can be messaged, and plans it with a warning when the person's words pin the agent.
    @Test func anAgentWhoseWorkersCannotBeMessagedIsRefusedUnlessPinned() async throws {
        let (world, run) = try makeWorld()
        world.link.attached = true
        world.daemon.deliveryVerdicts[.codex] = DeliveryVerdict(policy: .auto, version: "0.150.0")
        let refused = await create(world, run, "PLUTO-1")
        #expect(refused.message == "Codex’s workers can’t be messaged: Codex 0.160.0 is installed, but AiTerm's delivery check passed 0.150.0 only. "
                + "A task on it can’t be steered with message_task or get review fixes. Plan it on Claude, which can be messaged, "
                + "or set agentPinned if the person’s words name Codex.")
        #expect(world.state.tasks.isEmpty)
        let pinned = await world.call(run.id, "create_task", ["key": "PLUTO-2", "title": "B", "brief": "b", "project": "Shop", "agent": "codex",
                                                              "model": "gpt-6-astra", "modelReason": "The prompt says Codex.", "agentPinned": true])
        #expect(pinned.value?["created"] == true)
        #expect(pinned.value?["warning"] == .string("Codex’s workers can’t be messaged: Codex 0.160.0 is installed, but AiTerm's delivery check passed 0.150.0 only. "
                + "This task can’t be steered with message_task or get review fixes."))
    }

    /// With no installed agent that can be messaged there is nowhere better to plan it: it is planned, with the warning.
    /// A paste-only agent is planned too, and told that each message waits for the person's Enter.
    @Test func withNoAgentToMessageOrAPasteOnlyOneTheTaskIsPlannedWithAWarning() async throws {
        let (world, run) = try makeWorld()
        world.link.attached = true
        world.daemon.deliveryVerdicts = [.codex: DeliveryVerdict(policy: .off, version: nil), .claude: DeliveryVerdict(policy: .off, version: nil)]
        let alone = await create(world, run, "PLUTO-1")
        #expect(alone.value?["created"] == true)
        #expect(alone.value?["warning"] == .string("Codex’s workers can’t be messaged: AiTerm's delivery check hasn't passed Codex 0.160.0. "
                + "This task can’t be steered with message_task or get review fixes."))
        world.daemon.deliveryVerdicts[.codex] = DeliveryVerdict(policy: .pasteOnly, version: "0.160.0")
        let paste = await create(world, run, "PLUTO-2")
        #expect(paste.value?["created"] == true)
        #expect(paste.value?["warning"] == "Messages to its workers are pasted without Enter: the person presses Enter to send each one.")
        world.daemon.deliveryVerdicts[.codex] = DeliveryVerdict(policy: .auto, version: "0.160.0")
        #expect(await create(world, run, "PLUTO-3").value?["warning"] == nil)
    }

    /// run_status says, for each installed agent, whether its workers can be messaged and which version was checked.
    @Test func runStatusSaysWhetherEachAgentCanBeMessaged() async throws {
        let (world, run) = try makeWorld()
        world.link.attached = true
        world.daemon.deliveryVerdicts[.codex] = DeliveryVerdict(policy: .auto, version: "0.150.0")
        let agents = try #require(await world.call(run.id, "run_status").value?["run"]?["agents"])
        #expect(agents["claude"]?["delivery"]?["messaging"] == "auto" && agents["claude"]?["delivery"]?["checkedVersion"] == "2.1.301")
        let codex = try #require(agents["codex"]?["delivery"])
        #expect(codex["messaging"] == "off" && codex["installedVersion"] == "0.160.0" && codex["checkedVersion"] == "0.150.0")
        world.link.attached = false
        #expect(await world.call(run.id, "run_status").value?["run"]?["agents"]?["codex"]?["delivery"] == nil, "no helper: not known")
    }

    @Test func anUnknownModelIsRefusedWithTheList() async throws {
        let (world, run) = try makeWorld()
        let refused = await world.call(run.id, "create_task", ["key": "A", "title": "A", "brief": "a", "project": "Shop", "agent": "codex",
                                                               "model": "gpt-4o", "modelReason": "From memory."])
        #expect(refused.message == "gpt-4o isn’t in Codex’s model list in Settings › Agents. Its models are: gpt-6-astra, gpt-6-mini.")
        #expect(world.state.tasks.isEmpty)
        let switched = await world.call(run.id, "create_task", ["key": "B", "title": "B", "brief": "b", "project": "Shop", "agent": "codex",
                                                                "model": "gpt-6-mini", "modelReason": "A small change."])
        #expect(switched.value?["created"] == true)
        _ = await world.call(run.id, "update_task", ["task": "B", "model": "claude-named"])
        #expect(world.state.tasks.first?.model == "gpt-6-mini", "update_task checks the list too")
    }

    @Test func endDefaultsToCommitWithoutAConnectedHost() async throws {
        let (world, run) = try makeWorld()
        _ = await world.call(run.id, "create_task", ["key": "A", "title": "A", "brief": "a", "project": "Shop", "agent": "codex",
                                                     "modelReason": "The default."])
        #expect(operated(world, "A")?.end == .commit)
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.done = "A commit per item, tests green." } }
        _ = await world.call(run.id, "create_task", ["key": "B", "title": "B", "brief": "b", "project": "Shop", "agent": "codex",
                                                     "modelReason": "The default."])
        #expect(operated(world, "B")?.end == .commit, "a Done that says a commit ends there")
        for done in ["A draft MR per commit.", "Merged once each commit is green."] {
            #expect(OperatorToolHandler.defaultEnd(for: OperatorRun(id: run.id, name: "n", profile: run.profile, prompt: "p", done: done,
                                                                    createdAt: Date())) == .draftMR, "\(done)")
        }
    }

    /// No project joins a broadcast: a task goes in one of the run's own.
    @Test func aProjectOutsideTheRunIsRefused() async throws {
        let (world, run) = try makeWorld()
        #expect(await create(world, run, "C", project: "Docs").message == "Docs isn’t one of this broadcast’s projects: Shop, Web.")
        #expect(world.run(run.id)?.projectIds == [project.id, other.id] && world.state.tasks.isEmpty)
    }

    /// A run whose first plan, one task, was submitted: one addition goes in on the Operator's word.
    func makeBacklogWorld(oracle: Bool, runner: SecondOpinionRunner = .unavailable,
                          budget: Duration = .seconds(60), jira: FakeJira? = nil) throws -> (OperatorWorld, OperatorRun) {
        var run = OperatorServiceFixtures.run(OperatorServiceFixtures.profile(oracle: oracle, oracleAgent: .claude), projects: [project, other],
                                              state: .active, planRevision: 1)
        run.firstPlanSize = 1
        if jira != nil { run.profile.slices.jira = true; run.jiraProjectKeys = ["PLUTO"] }
        let first = OperatorServiceFixtures.task(in: run, project: project, key: "FIRST", state: .queued)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project, other], runs: [run], tasks: [first])) { ports in
            ports.milestone = .m1
            ports.secondOpinion = runner
            ports.challengeReplyBudget = budget
            if let jira { ports.jira = { jira } }
        }
        world.link.attached = false
        return (world, run)
    }

    func finds(_ world: OperatorWorld, _ run: OperatorRun) -> [OffBriefFind] { world.run(run.id)?.finds ?? [] }

    /// A no within the reply budget refuses at once, and AiTerm notes the addition for the debrief with the Oracle's reason.
    @Test func anAdditionPastTheThresholdNeedsTheOraclesYes() async throws {
        let (world, run) = try makeBacklogWorld(oracle: true, runner: .answering("NO. A dark mode is not in the sprint."))
        #expect(await create(world, run, "FREE").value?["created"] == true, "a quarter of one, at least one, goes free")
        #expect(await create(world, run, "PAST").message == "The Oracle judged this off-brief. AiTerm noted it for the debrief.")
        #expect(world.state.tasks.count == 2 && operated(world, "PAST") == nil)
        #expect(finds(world, run) == [OffBriefFind(key: "PAST", title: "Fix PAST", why: "A dark mode is not in the sprint.")])
        #expect(world.run(run.id)?.challenges.isEmpty == true, "an answer within the budget keeps no record")
        _ = await create(world, run, "PAST")
        #expect(finds(world, run).count == 1, "noted once per key")

        let (yes, yesRun) = try makeBacklogWorld(oracle: true, runner: .answering("YES\nIt is part of PLUTO-231."))
        _ = await create(yes, yesRun, "FREE")
        #expect(await create(yes, yesRun, "PAST").value?["created"] == true)
        #expect(operated(yes, "PAST")?.state == .planned && finds(yes, yesRun).isEmpty)
    }

    /// The veto is not held to the reply budget: it answers pending, and the call again with its id acts on a yes.
    @Test func aPendingVetoThenAYesAppends() async throws {
        let gate = OracleGate()
        let (world, run) = try makeBacklogWorld(oracle: true, runner: .answering("YES", gate: gate), budget: .milliseconds(20))
        _ = await create(world, run, "FREE")
        let first = await create(world, run, "PAST")
        #expect(first.value?["pending"] == true && operated(world, "PAST") == nil)
        let id = try #require(first.value?["challengeId"]?.stringValue)
        await gate.open()
        await world.controller.tools.lastChallenge?.value
        let acted = await create(world, run, "PAST", challengeId: id)
        #expect(acted.value?["created"] == true && operated(world, "PAST")?.state == .planned)
        #expect(await create(world, run, "PAST", challengeId: id) == acted, "the acting call again replays")
        #expect(world.state.tasks.count == 3 && finds(world, run).isEmpty)
    }

    @Test func aPendingVetoThenANoRefuses() async throws {
        let gate = OracleGate()
        let (world, run) = try makeBacklogWorld(oracle: true, runner: .answering("NO\nNot in the brief.", gate: gate), budget: .milliseconds(20))
        _ = await create(world, run, "FREE")
        let id = try #require(await create(world, run, "PAST").value?["challengeId"]?.stringValue)
        #expect(await create(world, run, "PAST", challengeId: id).value?["pending"] == true, "still judging")
        await gate.open()
        await world.controller.tools.lastChallenge?.value
        #expect(await create(world, run, "PAST", challengeId: id).message == "The Oracle judged this off-brief. AiTerm noted it for the debrief.")
        #expect(operated(world, "PAST") == nil && finds(world, run).map(\.why) == ["Not in the brief."])
    }

    /// The veto may take the Oracle's whole limit, `challengeTimeout`; past it, it is no answer, which is no.
    @Test func anOracleTimeoutPastTheThresholdRefuses() async throws {
        let asked = Mutex<Duration?>(nil)
        let timingOut = SecondOpinionRunner(locate: { "/opt/bin/\($0)" }, run: { _, _, _, _, timeout in
            asked.withLock { $0 = timeout }
            return ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: true)
        })
        let (world, run) = try makeBacklogWorld(oracle: true, runner: timingOut)
        _ = await create(world, run, "FREE")
        #expect(await create(world, run, "PAST").message == "The Oracle didn’t answer in time. AiTerm noted it for the debrief.")
        #expect(asked.withLock { $0 } == .seconds(OperatorTiming.challengeTimeout))
        #expect(world.state.tasks.count == 2 && finds(world, run).map(\.why) == ["The Oracle didn’t answer in time."])
        let (silent, silentRun) = try makeBacklogWorld(oracle: true, runner: .unavailable)
        _ = await create(silent, silentRun, "FREE")
        #expect(await create(silent, silentRun, "PAST").message == "The Oracle didn’t answer in time. AiTerm noted it for the debrief.",
                "an Oracle that cannot run is no yes")
    }

    /// A veto still running when AiTerm quit never acts after the restart.
    @Test func aVetoLostWithARestartRefuses() async throws {
        let (world, run) = try makeBacklogWorld(oracle: true, runner: .answering("YES", after: .seconds(30)), budget: .milliseconds(20))
        defer { world.controller.tools.cancelChallenges() }
        _ = await create(world, run, "FREE")
        let id = try #require(await create(world, run, "PAST").value?["challengeId"]?.stringValue)
        #expect(world.workspace.flush())
        let restarted = try OperatorWorld(try world.workspace.file.load())
        restarted.link.attached = false
        #expect(await create(restarted, run, "PAST", challengeId: id).message == "The Oracle didn’t answer in time. AiTerm noted it for the debrief.")
        #expect(restarted.state.tasks.count == 2 && finds(restarted, run).map(\.key) == ["PAST"])
    }

    @Test func withTheOracleOffAnAdditionPastTheThresholdIsRefused() async throws {
        let (world, run) = try makeBacklogWorld(oracle: false)
        #expect(await create(world, run, "FREE").value?["created"] == true)
        #expect(await create(world, run, "PAST").message == "Past the backlog limit with the Oracle off. AiTerm noted it for the debrief.")
        #expect(world.state.tasks.count == 2)
        #expect(finds(world, run) == [OffBriefFind(key: "PAST", title: "Fix PAST", why: "Past the backlog limit with the Oracle off.")])
        #expect(await create(world, run, "FREE").value?["created"] == false, "a repeat of a key is no addition")
    }

    /// With the Jira slice on, the find AiTerm notes itself is filed like one the Operator reported.
    @Test func aRefusedAdditionIsFiledWithTheJiraSliceOn() async throws {
        let jira = FakeJira()
        let (world, run) = try makeBacklogWorld(oracle: false, jira: jira)
        _ = await create(world, run, "FREE")
        #expect(await create(world, run, "PAST").message
                == "Past the backlog limit with the Oracle off. AiTerm noted it for the debrief and filed it as PLUTO-101.")
        #expect(jira.writes == [.create(project: "PLUTO", type: "Task", summary: "Fix PAST", description: "Past the backlog limit with the Oracle off.", parent: nil)])
        #expect(finds(world, run) == [OffBriefFind(key: "PAST", title: "Fix PAST", why: "Past the backlog limit with the Oracle off.", ticket: "PLUTO-101")])
        _ = await create(world, run, "PAST")
        #expect(jira.writes.count == 1, "once per key")
        jira.failWrites()
        #expect(await create(world, run, "LATER").message
                == "Past the backlog limit with the Oracle off. AiTerm noted it for the debrief. It could not be filed: Jira returned an error (HTTP 500). Try again.")
        #expect(finds(world, run).last?.ticket == nil)
    }

    @Test func aTaskOutsideTheWorkspaceOrAnAgentTheOperatorCannotRunIsRefused() async throws {
        let (world, run) = try makeWorld()
        #expect(await create(world, run, "A", project: "Elsewhere").message == "Elsewhere isn’t one of this broadcast’s projects: Shop, Web.")
        let grok = await world.call(run.id, "create_task", ["key": "B", "title": "B", "brief": "b", "project": "Shop", "agent": "grok",
                                                            "modelReason": "m"])
        #expect(grok.message == "The Operator’s task runs claude or codex.")
        #expect(world.state.tasks.isEmpty)
    }

    @Test func aTaskStacksOnAtMostOneCodeParentInItsOwnProject() async throws {
        let (world, run) = try makeWorld()
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

    @Test func submittingAPlanAgainChangesNothing() async throws {
        let (world, run) = try makeWorld()
        _ = await create(world, run, "A")
        let submitted = await world.call(run.id, "submit_plan", ["revision": 1])
        #expect(submitted.value?["released"] == 1 && submitted.value?["openRevision"] == 2)
        #expect(submitted.value?["waitingForApproval"] == nil)
        #expect(operated(world, "A")?.state == .queued)
        #expect(world.run(run.id)?.planRevision == 1)
        let saved = world.state
        let again = await world.call(run.id, "submit_plan", ["revision": 1])
        #expect(again.value?["repeated"] == true && again.value?["revision"] == 1)
        // A repeat released nothing now, but it must not read as "nothing was released" either.
        #expect(again.value?["released"] == nil && again.value?["note"]?.stringValue?.contains("already submitted") == true)
        #expect(world.state == saved)
        #expect(await world.call(run.id, "submit_plan", ["revision": 5]).message == PlanRevision.Failure.unknownRevision(open: 2, asked: 5).description)
    }

    @Test func aSubmittedPlanStartsAtOnceWithNothingToApprove() async throws {
        let (world, run) = try makeWorld()
        _ = await create(world, run, "A")
        let first = await world.call(run.id, "submit_plan", ["revision": 1])
        #expect(first.value?["released"] == 1 && first.value?["submitted"] == true)
        #expect(operated(world, "A")?.state == .queued && world.run(run.id)?.state == .active)
        #expect(world.run(run.id)?.firstPlanSize == 1)
        #expect(world.notifications.posted.isEmpty, "a plan waits for nobody, so it notifies nobody")
        _ = await create(world, run, "B")
        #expect(operated(world, "B")?.state == .planned, "the open revision waits for its own submission")
        #expect(await world.call(run.id, "submit_plan", ["revision": 2]).value?["released"] == 1)
        #expect(operated(world, "B")?.state == .queued && world.run(run.id)?.firstPlanSize == 1)
    }

    /// M3 carries out every end; a stacked task whose end its parent can't carry is refused with the reason.
    @Test func aPlanWhoseStackedEndItsParentCannotCarryIsRefusedWithTheReason() async throws {
        let fixture = try GitFixture.withOrigin(branch: "feat/source")
        let project = OperatorServiceFixtures.project(path: fixture.path)
        var profile = OperatorServiceFixtures.profile()
        profile.slices.merge = true
        let run = OperatorServiceFixtures.run(profile, projects: [project])
        let host = FakeMergeHost()
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) { $0.publisher = { _ in host } }
        world.link.attached = false
        _ = await create(world, run, "A")
        _ = await create(world, run, "B", end: "draftMR", dependsOn: [["task": "A", "kind": "code"]])
        let why = try #require(PlanEndRules.refusal(for: world.state.tasks))
        let refused = await world.call(run.id, "submit_plan", ["revision": 1])
        #expect(refused.message == PlanRevision.Failure.endsDisagree(why).description)
        #expect(world.run(run.id)?.planRevision == 0 && operated(world, "B")?.state == .planned)
        _ = await world.call(run.id, "update_task", ["task": "A", "end": "merge"])
        #expect(await world.call(run.id, "submit_plan", ["revision": 1]).value?["submitted"] == true)
    }

    @Test func updateTaskChangesOnlyAnUnstartedTask() async throws {
        let (world, run) = try makeWorld()
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
        let (world, run) = try makeWorld()
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

    /// A model-only update checked against Claude's list while another update switches the task to Codex:
    /// the first never saves its Claude model on the Codex task, and says to call again.
    @Test func aModelCheckedForAnAgentTheTaskNoLongerHasIsRefused() async throws {
        let gate = Mutex((armed: false, entered: false))
        let release = DispatchSemaphore(value: 0)
        let run = OperatorServiceFixtures.run(projects: [project, other])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project, other, docs], runs: [run])) { ports in
            ports.milestone = .m1
            ports.agentModels = { agent in
                let hold = gate.withLock { gate in
                    guard gate.armed, agent == .claude, !gate.entered else { return false }
                    gate.entered = true
                    return true
                }
                if hold { release.wait() }
                return OperatorServiceFixtures.models[agent] ?? []
            }
        }
        world.link.attached = false
        _ = await world.call(run.id, "create_task", ["key": "A", "title": "A", "brief": "a", "project": "Shop", "agent": "claude",
                                                     "model": "claude-named", "modelReason": "The prompt says Claude."])
        try #require(world.state.tasks.first?.agent == .claude)
        gate.withLock { $0.armed = true }
        let first = Task { await world.call(run.id, "update_task", ["task": "A", "model": "claude-other"]) }
        await eventually(describing: "the first update reading Claude's list") { gate.withLock { $0.entered } }
        let switched = await world.call(run.id, "update_task", ["task": "A", "agent": "codex", "model": "gpt-6-mini"])
        #expect(switched.value?["created"] == false, "\(switched)")
        release.signal()
        let refused = await first.value
        #expect(refused.message == "The task’s agent changed while this update was checked: call update_task again.")
        let task = try #require(world.state.tasks.first)
        #expect(task.agent == .codex && task.model == "gpt-6-mini")
    }

    @Test func aRefusedCreateTaskLeavesTheOperationsProjectsAsTheyWere() async throws {
        let (world, run) = try makeWorld()
        let refused = await world.call(run.id, "create_task", ["key": "A", "title": "A", "brief": "a", "project": "Shop", "agent": "grok",
                                                               "modelReason": "m"])
        #expect(refused.message == "The Operator’s task runs claude or codex.")
        #expect(world.run(run.id)?.projectIds == [project.id, other.id] && world.state.tasks.isEmpty)
        #expect(await create(world, run, "B", project: "Shop", end: "nonsense").message == "A task’s end is commit, draftMR, merge or mergeLocal.")
        #expect(world.run(run.id)?.projectIds == [project.id, other.id])
        #expect(world.state.tasks.isEmpty)
    }

}

private extension Array {
    /// The one element, or nil when there are none or several.
    var only: Element? { count == 1 ? first : nil }
}

extension OperatorPlanToolsTests {
    @Test func forbiddenEndsAreRefusedBeforeTasksStart() async throws {
        let (world, run) = try makeWorld(milestone: .m3)
        for end in ["merge", "mergeLocal"] {
            #expect(await create(world, run, "A", end: end).message == "Merge is off for this broadcast: end it at a commit or a draft MR.")
        }
        #expect(await create(world, run, "A", end: "draftMR").message == "Shop has no connected code host: end it at a commit.")
        #expect(world.state.tasks.isEmpty)
        _ = await create(world, run, "A")
        #expect(await world.call(run.id, "update_task", ["task": "A", "end": "merge"]).message == "Merge is off for this broadcast: end it at a commit or a draft MR.")
        #expect(await world.call(run.id, "update_task", ["task": "A", "end": "draftMR"]).message == "Shop has no connected code host: end it at a commit.")
        #expect(operated(world, "A")?.end == .commit)
    }
}

extension OperatorPlanToolsTests {
    @Test func anOriginWithoutAConnectionRefusesRemoteEndsAndAConnectedOneDefaultsToDraft() async throws {
        let fixture = try GitFixture.withOrigin(branch: "feat/source")
        let project = OperatorServiceFixtures.project(path: fixture.path)
        let run = OperatorServiceFixtures.run(projects: [project])
        let disconnected = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]))
        #expect(await create(disconnected, run, "A", end: "draftMR").message == "Shop has no connected code host: end it at a commit.")
        let host = FakeMergeHost()
        let connected = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) { $0.publisher = { _ in host } }
        _ = await connected.call(run.id, "create_task", ["key": "A", "title": "A", "brief": "a", "project": "Shop", "agent": "codex", "modelReason": "The default."])
        #expect(operated(connected, "A")?.end == .draftMR)
    }
}
