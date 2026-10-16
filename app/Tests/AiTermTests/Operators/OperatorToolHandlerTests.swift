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
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.persona(autonomy: .askFirst), projects: [project])
        let world = try makeWorld(run)
        #expect(await world.call(run.id, "run_status").value?["revision"] == 1)
        #expect(await world.call(run.id, "run_status").value?["revision"] == 1)
        _ = await world.call(run.id, "ask_you", ["key": "locale", "question": "Which locale is the default?"])
        #expect(await world.call(run.id, "run_status").value?["revision"] == 2)
    }

    @Test func askingTwiceWithOneKeyKeepsOneQuestionNotifiesOnceAndResolvingClosesIt() async throws {
        let run = OperatorServiceFixtures.run(OperatorServiceFixtures.persona(autonomy: .askFirst), projects: [project])
        let world = try makeWorld(run)
        let first = await world.call(run.id, "ask_you", ["key": "locale", "question": "Which locale is the default?"])
        let again = await world.call(run.id, "ask_you", ["key": "locale", "question": "Which locale, again?"])
        #expect(first.value?["open"] == true && again.value?["open"] == true)
        #expect(world.run(run.id)?.questions.map(\.text) == ["Which locale is the default?"])
        #expect(world.notifications.posted.count == 1)
        let resolved = await world.call(run.id, "resolve_question", ["key": "locale", "summary": "nl-BE"])
        #expect(resolved.value?["open"] == false)
        #expect(world.run(run.id)?.questions.first?.resolution == "nl-BE")
        #expect(await world.call(run.id, "resolve_question", ["key": "nope", "summary": "x"]).message == "No question nope in this operation.")
    }

    @Test func aDecisionAndALessonAreWrittenOncePerKey() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        for _ in 0..<2 {
            _ = await world.call(run.id, "log_decision", ["key": "d1", "text": "Kept the old endpoint."])
            _ = await world.call(run.id, "propose_lesson", ["key": "l1", "lesson": "Ask before a migration.", "because": "You overruled me."])
        }
        #expect(world.run(run.id)?.decisions.map(\.text) == ["Kept the old endpoint."])
        #expect(world.run(run.id)?.lessons.map(\.lesson) == ["Ask before a migration."])
        #expect(world.run(run.id)?.lessons.first?.decided == nil)
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
        #expect(await world.call(run.id, "finish_task", ["task": "x"]).message?.hasPrefix("finish_task is available in M3.") == true)
        #expect(await world.call(run.id, "merge_everything").message == "AiTerm has no tool called merge_everything.")
        #expect(await world.call(UUID(), "run_status").message == "This operation is no longer in AiTerm.")
    }

    @Test func aRequestIsAnsweredThroughTheDaemonWithItsId() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        world.controller.handle(.operatorRequest(OperatorRequest(requestId: "r7", runId: run.id.uuidString, tool: "finish_task", arguments: [:])))
        await world.controller.tools.lastReply?.value
        let reply = try #require(world.daemon.requests("operator.reply").first)
        #expect(reply.params["requestId"] as? String == "r7")
        #expect((reply.params["error"] as? String)?.hasPrefix("finish_task is available in M3.") == true)
        #expect(reply.params["result"] == nil)
    }
}
