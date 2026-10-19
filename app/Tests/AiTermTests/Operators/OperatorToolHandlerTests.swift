import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The operator's read and record tools (spec §6), answered from the workspace.
@MainActor @Suite struct OperatorToolHandlerTests {
    let pluto = JiraProjectRef(id: "1", key: "PLUTO", name: "Pluto", siteURL: URL(string: "https://acme.atlassian.net")!)
    let project: Project
    init() { project = OperatorServiceFixtures.project(jira: [pluto]) }

    func makeWorld(_ run: OperatorRun, jira: FakeJira? = nil) throws -> OperatorWorld {
        try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) { ports in
            if let jira { ports.jira = { jira } }
        }
    }

    @Test func runStatusIsNumberedByWhatChanged() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        #expect(await world.call(run.id, "run_status").value?["revision"] == 1)
        #expect(await world.call(run.id, "run_status").value?["revision"] == 1)
        _ = await world.call(run.id, "ask_you", ["key": "locale", "question": "Which locale is the default?"])
        #expect(await world.call(run.id, "run_status").value?["revision"] == 2)
    }

    @Test func askingTwiceWithOneKeyKeepsOneQuestionNotifiesOnceAndResolvingClosesIt() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        let first = await world.call(run.id, "ask_you", ["key": "locale", "question": "Which locale is the default?"])
        let again = await world.call(run.id, "ask_you", ["key": "locale", "question": "Which locale, again?"])
        #expect(first.value?["open"] == true && again.value?["open"] == true)
        #expect(world.run(run.id)?.questions.map(\.text) == ["Which locale is the default?"])
        #expect(world.notifications.posted.map(\.body) == ["The Operator asks: Which locale is the default?"])
        let resolved = await world.call(run.id, "resolve_question", ["key": "locale", "summary": "nl-BE"])
        #expect(world.notifications.withdrawn == ["request-\(run.id.uuidString)-question-locale"])
        #expect(resolved.value?["open"] == false)
        #expect(world.run(run.id)?.questions.first?.resolution == "nl-BE")
        #expect(await world.call(run.id, "resolve_question", ["key": "nope", "summary": "x"]).message == "No question nope in this operation.")
    }

    @Test func aDecisionIsWrittenOncePerKey() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        for _ in 0..<2 {
            _ = await world.call(run.id, "log_decision", ["key": "d1", "text": "Kept the old endpoint."])
        }
        #expect(world.run(run.id)?.decisions.map(\.text) == ["Kept the old endpoint."])
    }

    /// Lessons went with the personas: the tool is no longer AiTerm's.
    @Test func proposeLessonIsGone() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        let answer = await world.call(run.id, "propose_lesson", ["key": "l1", "lesson": "Ask before a migration.", "because": "You overruled me."])
        #expect(answer.message == "AiTerm has no tool called propose_lesson.")
    }

    /// An off-brief find goes to the debrief, once per key, and run_status shows it.
    @Test func reportFindRecordsIt() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        let find = ["key": "leak", "title": "A token in the payments log", "why": "Anyone with log access can pay as the shop."] as JSONValue
        let answer = await world.call(run.id, "report_find", find)
        #expect(answer.value?["find"] == "leak" && answer.value?["recorded"] == true)
        _ = await world.call(run.id, "report_find", ["key": "leak", "title": "Again", "why": "Again."])
        #expect(world.run(run.id)?.finds == [OffBriefFind(key: "leak", title: "A token in the payments log",
                                                          why: "Anyone with log access can pay as the shop.")])
        #expect(await world.call(run.id, "run_status").value?["run"]?["finds"]?.arrayValue?.first?["key"] == "leak")
        #expect(await world.call(run.id, "report_find", ["key": "x", "title": "t"]).message == "report_find needs `why`.")
    }

    /// The Operator decided against the Oracle: the decision keeps the objection.
    @Test func aDecisionCarriesTheObjectionItOverruled() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        _ = await world.call(run.id, "log_decision", ["key": "d1", "text": "Kept one task.", "objection": "It is two changes."])
        #expect(world.run(run.id)?.decisions.first?.objection == "It is two changes.")
    }

    /// The model rule needs each installed agent's own list and its default (spec §15).
    @Test func runStatusListsEachInstalledAgentsModels() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) { $0.installedAgents = { [.codex] } }
        let agents = try #require(await world.call(run.id, "run_status").value?["run"]?["agents"])
        #expect(agents["claude"] == nil, "an agent not installed is left out")
        #expect(agents["codex"]?["models"] == ["gpt-6-astra", "gpt-6-mini"])
        let fallback = AgentIntegrations.fixerModels(remembered: world.state.lastModelByAgent)(.codex)
        #expect(agents["codex"]?["defaultModel"]?.stringValue == fallback.model)
    }

    @Test func jiraSearchIsKeptToTheOperationsLinkedJiraProjects() async throws {
        let jira = FakeJira(tickets: [JiraTicket(key: "PLUTO-231", summary: "Login", description: "Fix it.", issueType: "Bug",
                                                  status: "To Do", url: "https://acme.atlassian.net/browse/PLUTO-231")])
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run, jira: jira)
        let answer = await world.call(run.id, "jira_search", ["jql": "sprint in openSprints()"])
        #expect(answer.value?.arrayValue?.first?["key"] == "PLUTO-231")
        #expect(answer.value?.arrayValue?.first?["status"] == "To Do")
        #expect(jira.searches.map(\.projects) == [["PLUTO"]])
        #expect(jira.searches.map(\.jql) == ["sprint in openSprints()"])
    }

    @Test func jiraSearchWithoutJiraSaysWhere() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        #expect(await world.call(run.id, "jira_search", ["jql": "x"]).message == "Jira isn’t connected in AiTerm’s Settings › Integrations.")
    }

    @Test func finishTaskComesInM3AndAnUnknownToolOrRunIsAnError() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        #expect(await world.call(run.id, "finish_task", ["task": "x"]).message == "No task x in this operation.")
        #expect(await world.call(run.id, "merge_everything").message == "AiTerm has no tool called merge_everything.")
        #expect(await world.call(UUID(), "run_status").message == "This operation is no longer in AiTerm.")
    }

    @Test func aRequestIsAnsweredThroughTheDaemonWithItsId() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        world.controller.handle(.operatorRequest(OperatorRequest(requestId: "r7", runId: run.id.uuidString, tool: "merge_everything", arguments: [:])))
        await world.controller.tools.lastReply?.value
        let reply = try #require(world.daemon.requests("operator.reply").first)
        #expect(reply.params["requestId"] as? String == "r7")
        #expect(reply.params["error"] as? String == "AiTerm has no tool called merge_everything.")
        #expect(reply.params["result"] == nil)
    }

    /// A started task of `run`, as an operator names it by its key.
    func workingTask(in run: OperatorRun, key: String = "T1") -> TaskItem {
        OperatorServiceFixtures.task(in: run, project: project, key: key, state: .working, worktree: "/tmp/aiterm-operators-wt-\(key)")
    }

    func makeWorld(_ run: OperatorRun, tasks: [TaskItem]) throws -> OperatorWorld {
        try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: tasks))
    }

    @Test func aQuestionAboutATaskMarksItWaitingOnYouUntilNoneOfItsQuestionsIsOpen() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let task = workingTask(in: run)
        let world = try makeWorld(run, tasks: [task])
        func waiting() -> Bool { world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == true }
        _ = await world.call(run.id, "ask_you", ["key": "a", "question": "First?", "task": "T1"])
        _ = await world.call(run.id, "ask_you", ["key": "b", "question": "Second?", "task": .string(task.id.uuidString)])
        #expect(waiting())
        #expect(world.run(run.id)?.questions.map(\.task) == [task.id, task.id])
        _ = await world.call(run.id, "resolve_question", ["key": "a", "summary": "yes"])
        #expect(waiting())
        _ = await world.call(run.id, "resolve_question", ["key": "b", "summary": "no"])
        #expect(!waiting())
    }

    @Test func aRepeatedResolveReturnsTheRecordedResolution() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        _ = await world.call(run.id, "ask_you", ["key": "locale", "question": "Which locale?"])
        _ = await world.call(run.id, "resolve_question", ["key": "locale", "summary": "nl-BE"])
        let again = await world.call(run.id, "resolve_question", ["key": "locale", "summary": "fr-BE"])
        #expect(again.value?["open"] == false)
        #expect(again.value?["resolution"] == "nl-BE")
        #expect(world.run(run.id)?.questions.first?.resolution == "nl-BE")
    }

    @Test func anEndedOperationsToolsDoNotAct() async throws {
        let stopped = OperatorServiceFixtures.run(projects: [project], state: .stopped)
        let world = try makeWorld(stopped)
        let ended = "This operation has ended; its tools no longer act."
        #expect(await world.call(stopped.id, "ask_you", ["key": "k", "question": "Q?"]).message == ended)
        #expect(world.run(stopped.id)?.questions.isEmpty == true)
        // Ended by you, its state not yet caught up.
        let live = OperatorServiceFixtures.run(projects: [project])
        let second = try makeWorld(live)
        second.workspace.mutate { $0.updateRun(id: live.id) { $0.intent = .stopped } }
        #expect(await second.call(live.id, "run_status").message == ended)
    }

    @Test func jiraSearchNeedsAJiraProjectLinkedToTheOperation() async throws {
        let unlinked = OperatorServiceFixtures.project(name: "Plain")
        let run = OperatorServiceFixtures.run(projects: [unlinked])
        let jira = FakeJira(tickets: [])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [unlinked], runs: [run])) { $0.jira = { jira } }
        let answer = await world.call(run.id, "jira_search", ["jql": "x"])
        #expect(answer.message == "None of this operation’s projects is linked to a Jira project, so there is nothing jira_search may search.")
        #expect(jira.searches.isEmpty)
    }

    @Test func aMissingArgumentOrAnUnknownTaskIsSaidPlainly() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        #expect(await world.call(run.id, "ask_you", ["key": "k"]).message == "ask_you needs `question`.")
        #expect(await world.call(run.id, "ask_you", ["key": "k", "question": "   "]).message == "ask_you needs `question`.")
        #expect(await world.call(run.id, "jira_search").message == "jira_search needs `jql`.")
        #expect(await world.call(run.id, "log_decision", ["key": "d", "text": "t", "task": "nope"]).message == "No task nope in this operation.")
        #expect(await world.call(run.id, "ask_you", ["key": "k", "question": "Q?", "task": "nope"]).message == "No task nope in this operation.")
        #expect(world.run(run.id)?.questions.isEmpty == true && world.run(run.id)?.decisions.isEmpty == true)
    }

    @Test func aToolThatActsOnATaskTellsWhenItStartsAndStops() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let task = workingTask(in: run)
        let world = try makeWorld(run, tasks: [task])
        var events: [String] = []
        world.controller.tools.onActing = { id, on in events.append("\(id == task.id ? "T1" : "?") \(on)") }
        _ = await world.call(run.id, "finish_task", ["task": "T1"])
        #expect(events == ["T1 true", "T1 false"])
        events = []
        _ = await world.call(run.id, "message_task", ["task": .string(task.id.uuidString), "text": "hi"])
        #expect(events == ["T1 true", "T1 false"])
        // A tool that does not act on a task, or names none, tells nothing; the row is not left breathing.
        events = []
        _ = await world.call(run.id, "run_status")
        _ = await world.call(run.id, "finish_task", ["task": "nope"])
        #expect(events.isEmpty)
        #expect(world.controller.acting.isEmpty)
    }
}
