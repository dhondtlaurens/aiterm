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

    /// The Operator says why in a sentence, and the debrief shows it under the decision.
    @Test func aDecisionCarriesItsWhy() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        _ = await world.call(run.id, "log_decision", ["key": "d1", "text": "Added Retry failed payments (PAY-240)",
                                                      "why": "The provider switch left failed payments with no retry."])
        _ = await world.call(run.id, "log_decision", ["key": "d2", "text": "Kept the old endpoint."])
        let decisions = try #require(world.run(run.id)?.decisions)
        #expect(decisions.map(\.why) == ["The provider switch left failed payments with no retry.", nil])
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

    // -- Jira writes (spec §5): the first slice -----------------------------------------------------

    /// A run whose frozen Jira slice is `slice`, in the Jira projects PLUTO and WEB.
    func jiraRun(slice: Bool) -> OperatorRun {
        var run = OperatorServiceFixtures.run(projects: [project])
        run.profile.slices.jira = slice
        run.jiraProjectKeys = ["PLUTO", "WEB"]
        return run
    }

    /// A `jira_create` call for PLUTO, with `changes` over its arguments.
    func ticket(_ changes: [String: JSONValue] = [:]) -> JSONValue {
        .object(["key": "t1", "project": "PLUTO", "type": "Task", "summary": "Handle SIGTERM", "description": "Drain the tasks."]
            .merging(changes) { _, new in new })
    }

    @Test func jiraWritesNeedTheSlice() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: false)
        let world = try makeWorld(run, jira: jira)
        let off = "The Jira slice is off for this broadcast."
        #expect(await world.call(run.id, "jira_create", ticket()).message == off)
        #expect(await world.call(run.id, "jira_move", ["key": "PLUTO-231", "status": "Done"]).message == off)
        #expect(await world.call(run.id, "jira_link", ["key": "PLUTO-1", "to": "WEB-2", "type": "Blocks"]).message == off)
        #expect(jira.writes.isEmpty)
        #expect(world.run(run.id)?.leftForYou == ["Create the Jira ticket “Handle SIGTERM” in PLUTO: the Jira slice is off.",
                                                  "Move PLUTO-231 to Done: the Jira slice is off.",
                                                  "Link PLUTO-1 to WEB-2 (Blocks): the Jira slice is off."])
        _ = await world.call(run.id, "jira_move", ["key": "PLUTO-231", "status": "Done"])
        #expect(world.run(run.id)?.leftForYou.count == 3, "the same sentence is kept once")
    }

    @Test func jiraWritesWithTheSliceOnReachTheClient() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        let made = await world.call(run.id, "jira_create", ticket(["parent": "pluto-7"]))
        #expect(made.value?["key"] == "PLUTO-101")
        #expect(await world.call(run.id, "jira_move", ["key": "pluto-231", "status": "Done"]).value?["moved"] == true)
        #expect(await world.call(run.id, "jira_link", ["key": "PLUTO-1", "to": "WEB-2", "type": "Blocks"]).value?["linked"] == true)
        #expect(jira.writes == [.create(project: "PLUTO", type: "Task", summary: "Handle SIGTERM", description: "Drain the tasks.", parent: "PLUTO-7"),
                                .move(key: "PLUTO-231", status: "Done"), .link(key: "PLUTO-1", to: "WEB-2", type: "Blocks")])
        #expect(world.run(run.id)?.leftForYou.isEmpty == true)
        #expect(await world.call(run.id, "jira_create", ["key": "t2", "project": "PLUTO", "type": "Task", "description": "d"]).message == "jira_create needs `summary`.")
        #expect(await world.call(run.id, "jira_create", ["project": "PLUTO", "type": "Task", "summary": "s", "description": "d"]).message == "jira_create needs `key`.")
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.profile.slices.jira = false } }
        #expect(await world.call(run.id, "jira_move", ["key": "PLUTO-1", "status": "Done"]).message == "The Jira slice is off for this broadcast.",
                "the slice is read as it is when the call acts")
    }

    @Test func jiraWritesStayInScope() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        let outside = "isn’t in this broadcast’s Jira projects: PLUTO, WEB."
        #expect(await world.call(run.id, "jira_move", ["key": "PAY-9", "status": "Done"]).message == "PAY-9 \(outside)")
        #expect(await world.call(run.id, "jira_create", ticket(["project": "PAY"])).message == "PAY \(outside)")
        #expect(await world.call(run.id, "jira_create", ticket(["parent": "PAY-1"])).message == "PAY-1 \(outside)")
        #expect(await world.call(run.id, "jira_link", ["key": "PLUTO-1", "to": "PAY-2", "type": "Blocks"]).message == "PAY-2 \(outside)")
        #expect(await world.call(run.id, "jira_link", ["key": "PAY-2", "to": "PLUTO-1", "type": "Blocks"]).message == "PAY-2 \(outside)")
        #expect(await world.call(run.id, "jira_move", ["key": "PLUTO", "status": "Done"]).message == "PLUTO isn’t a Jira ticket key like PLUTO-231.")
        #expect(jira.writes.isEmpty)
        #expect(world.run(run.id)?.leftForYou.isEmpty == true, "a write outside the scope is nobody's to do for this broadcast")
        // Out of scope is refused whatever the slice says.
        let off = jiraRun(slice: false)
        let offWorld = try makeWorld(off, jira: jira)
        #expect(await offWorld.call(off.id, "jira_move", ["key": "PAY-9", "status": "Done"]).message == "PAY-9 \(outside)")
        #expect(offWorld.run(off.id)?.leftForYou.isEmpty == true)
    }

    /// The Operator's retry after a lost reply is the same ticket, however many times.
    @Test func jiraCreateIsSafeToRepeat() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        let first = await world.call(run.id, "jira_create", ticket())
        let again = await world.call(run.id, "jira_create", ticket(["summary": "Another words"]))
        #expect(first.value?["key"] == "PLUTO-101" && first.value?["created"] == true)
        #expect(again.value?["key"] == "PLUTO-101" && again.value?["created"] == false)
        #expect(jira.writes.count == 1, "one POST for one key")
        #expect(world.run(run.id)?.jiraCreated == ["t1": "PLUTO-101"])
        #expect(await world.call(run.id, "jira_create", ticket(["key": "t2"])).value?["key"] == "PLUTO-102")
        // A failed create records nothing: the same key may try again.
        let broken = FakeJira()
        broken.failWrites()
        let other = jiraRun(slice: true)
        let otherWorld = try makeWorld(other, jira: broken)
        #expect(await otherWorld.call(other.id, "jira_create", ticket()).message == "Jira returned an error (HTTP 500). Try again.")
        broken.failWrites(false)
        #expect(await otherWorld.call(other.id, "jira_create", ticket()).value?["created"] == true)
    }

    @Test func jiraMoveToTheStatusItIsInSucceedsWithoutATransition() async throws {
        let jira = FakeJira()
        jira.put("PLUTO-231", in: "Done")
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        let answer = await world.call(run.id, "jira_move", ["key": "PLUTO-231", "status": "Done"])
        #expect(answer.value?["moved"] == false && answer.value?["note"] == "PLUTO-231 is already in Done.")
        #expect(jira.writes.isEmpty)
    }

    /// Jira's own words reach the Operator, so it can correct the call; and the find keeps them as why it was not filed.
    @Test func aJiraRefusalIsToldInJirasWords() async throws {
        let jira = FakeJira()
        jira.refuseWrites("issuetype: Specify a valid issue type.")
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        #expect(await world.call(run.id, "jira_create", ticket()).message == "Jira refused it (HTTP 400): issuetype: Specify a valid issue type.")
        let find = await world.call(run.id, "report_find", ["key": "f", "title": "t", "why": "w"])
        #expect(find.value?["notFiled"] == "Jira refused it (HTTP 400): issuetype: Specify a valid issue type.")
    }

    @Test func jiraWritesWithoutJiraOrAFailureSayWhy() async throws {
        let run = jiraRun(slice: true)
        let none = try makeWorld(run)
        #expect(await none.call(run.id, "jira_create", ticket()).message == "Jira isn’t connected in AiTerm’s Settings › Integrations.")
        let jira = FakeJira()
        jira.failWrites()
        let world = try makeWorld(run, jira: jira)
        #expect(await world.call(run.id, "jira_move", ["key": "PLUTO-1", "status": "Done"]).message == "Jira returned an error (HTTP 500). Try again.")
    }

    /// With the slice on, an off-brief find is a Task in the first Jira project, and the find keeps its key.
    @Test func aFindIsFiledWithTheSliceOn() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        let find = ["key": "leak", "title": "A token in the payments log", "why": "Anyone with log access can pay as the shop."] as JSONValue
        let answer = await world.call(run.id, "report_find", find)
        #expect(answer.value?["recorded"] == true && answer.value?["ticket"] == "PLUTO-101")
        #expect(jira.writes == [.create(project: "PLUTO", type: "Task", summary: "A token in the payments log",
                                        description: "Anyone with log access can pay as the shop.", parent: nil)])
        #expect(world.run(run.id)?.finds == [OffBriefFind(key: "leak", title: "A token in the payments log",
                                                          why: "Anyone with log access can pay as the shop.", ticket: "PLUTO-101")])
        #expect(await world.call(run.id, "report_find", find).value?["ticket"] == "PLUTO-101")
        #expect(jira.writes.count == 1, "a repeat files nothing twice")
        #expect(await world.call(run.id, "run_status").value?["run"]?["finds"]?.arrayValue?.first?["ticket"] == "PLUTO-101")
    }

    @Test func aFindIsNotFiledWithTheSliceOffOrFailsWithItsReason() async throws {
        let find = ["key": "leak", "title": "A token", "why": "It leaks."] as JSONValue
        let jira = FakeJira()
        let off = jiraRun(slice: false)
        let offWorld = try makeWorld(off, jira: jira)
        let recorded = await offWorld.call(off.id, "report_find", find)
        #expect(recorded.value?["recorded"] == true && recorded.value?["ticket"] == nil)
        #expect(jira.writes.isEmpty && offWorld.run(off.id)?.leftForYou.isEmpty == true)

        let run = jiraRun(slice: true)
        let broken = FakeJira()
        broken.failWrites()
        let world = try makeWorld(run, jira: broken)
        let answer = await world.call(run.id, "report_find", find)
        #expect(answer.value?["recorded"] == true && answer.value?["ticket"] == nil)
        #expect(answer.value?["notFiled"] == "Jira returned an error (HTTP 500). Try again.")
        #expect(world.run(run.id)?.finds == [OffBriefFind(key: "leak", title: "A token", why: "It leaks.")], "the find is kept, with no ticket")
        broken.failWrites(false)
        #expect(await world.call(run.id, "report_find", find).value?["ticket"] == "PLUTO-101", "calling again files it")
        #expect(world.run(run.id)?.finds.first?.ticket == "PLUTO-101")
    }

    /// No Jira project in the broadcast, or Jira not connected: the find is kept and the answer says so.
    @Test func aFindWithNowhereToFileItIsKept() async throws {
        let find = ["key": "leak", "title": "A token", "why": "It leaks."] as JSONValue
        var run = jiraRun(slice: true)
        run.jiraProjectKeys = []
        let world = try makeWorld(run, jira: FakeJira())
        #expect(await world.call(run.id, "report_find", find).value?["notFiled"] == "This broadcast has no Jira project to file it in.")
        let unconnected = jiraRun(slice: true)
        let bare = try makeWorld(unconnected)
        #expect(await bare.call(unconnected.id, "report_find", find).value?["notFiled"] == "Jira isn’t connected in AiTerm’s Settings › Integrations.")
        #expect(bare.run(unconnected.id)?.finds.map(\.ticket) == [nil])
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
        world.controller.tools.onActing = { activity, on in
            events.append("\(activity.task == task.id ? "T1" : "?") \(activity.act.rawValue) \(on)")
        }
        _ = await world.call(run.id, "finish_task", ["task": "T1"])
        #expect(events == ["T1 checkingTheWork true", "T1 checkingTheWork false"])
        events = []
        _ = await world.call(run.id, "message_task", ["task": .string(task.id.uuidString), "text": "hi"])
        #expect(events == ["T1 answering true", "T1 answering false"])
        // A tool that is none of the Operator's acts, or names no task of the run, tells nothing.
        events = []
        _ = await world.call(run.id, "run_status")
        _ = await world.call(run.id, "finish_task", ["task": "nope"])
        #expect(events.isEmpty)
        #expect(world.controller.acting == .none)
    }

    /// Each tool that is one of the Operator's acts maps to its act, by what the task is doing and how it ends.
    @Test func eachActingToolIsItsAct() {
        let run = OperatorServiceFixtures.run(projects: [project])
        func act(_ tool: String, _ state: OperatedState = .working, end: TaskEnd = .commit, request: Bool = false) -> OperatorAct? {
            var task = workingTask(in: run)
            task.operated?.state = state
            task.operated?.end = end
            if request { task.operated?.publication = TaskPublication(mergeRequestURL: "https://gitlab.example/a/-/merge_requests/1") }
            return OperatorToolHandler.act(for: tool, on: task)
        }
        #expect(act("message_task") == .answering)
        #expect(act("message_task", .inReview) == .fixingReviewFeedback)
        #expect(act("reply_thread", .inReview) == .fixingReviewFeedback)
        #expect(act("mark_task") == .checkingTheWork)
        #expect(act("review_task") == .reviewingWith)
        #expect(act("request_review") == .assigning)
        #expect(act("finish_task") == .checkingTheWork)
        #expect(act("finish_task", end: .draftMR) == .openingTheMR)
        #expect(act("finish_task", end: .merge) == .openingTheMR)
        #expect(act("finish_task", .inReview, end: .merge, request: true) == .merging)
        #expect(act("finish_task", end: .mergeLocal) == .merging)
        #expect(act("run_status") == nil && act("read_task") == nil)
        #expect(OperatorToolHandler.actsOnBroadcast["submit_plan"] == .loadingTheConstruct)
        #expect(OperatorToolHandler.actsOnBroadcast["jira_create"] == .filingATicket)
    }

    // MARK: - Gate C: Jira writes wait while the operation does not run, and a lost answer makes no second ticket

    /// The label `jira_create` gives the ticket for `key` in `run`.
    static func label(_ run: OperatorRun, _ key: String) -> String { "aiterm-\(run.id.uuidString.prefix(8).lowercased())-\(key)" }

    @Test(arguments: [(OperatorRunState.active, OperatorRunState?.some(.paused)), (.paused, .paused), (.operatorOffline, nil),
                      (.planning, .paused)])
    func jiraWritesWaitWhileTheOperationDoesNotRun(_ state: OperatorRunState, _ intent: OperatorRunState?) async throws {
        let jira = FakeJira()
        var run = jiraRun(slice: true)
        run.state = state
        run.intent = intent
        let world = try makeWorld(run, jira: jira)
        #expect(await world.call(run.id, "jira_create", ticket()).message != nil)
        #expect(await world.call(run.id, "jira_move", ["key": "PLUTO-231", "status": "Done"]).message != nil)
        #expect(await world.call(run.id, "jira_link", ["key": "PLUTO-1", "to": "WEB-2", "type": "Blocks"]).message != nil)
        let find = await world.call(run.id, "report_find", ["key": "f", "title": "Flaky test", "why": "It fails on CI."])
        #expect(find.value?["recorded"] == true && find.value?["ticket"] == nil, "the find is kept, not filed")
        #expect(jira.writes.isEmpty)
    }

    /// Jira reads the ticket's status and its transitions before it moves it: a Pause meanwhile moves nothing.
    @Test func aPauseWhileJiraIsReadMovesNothing() async throws {
        let jira = FakeJira()
        var run = jiraRun(slice: true)
        run.state = .active
        let world = try makeWorld(run, jira: jira)
        jira.beforeTransition.withLock { $0 = { @MainActor in world.workspace.mutate { $0.updateRun(id: run.id) { $0.intent = .paused } } } }
        #expect(await world.call(run.id, "jira_move", ["key": "PLUTO-231", "status": "Done"]).message == "The person paused this operation. Wait until they resume it.")
        #expect(jira.writes.isEmpty)
    }

    @Test func aCreatedTicketIsSavedBeforeItIsAnswered() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        #expect(await world.call(run.id, "jira_create", ticket()).value?["key"] == "PLUTO-101")
        #expect(try world.workspace.file.load().run(id: run.id)?.jiraCreated == ["t1": "PLUTO-101"])
        #expect(jira.labels["PLUTO-101"] == [Self.label(run, "t1")])
    }

    @Test func aCreateWhoseAnswerWasLostAdoptsTheTicketItMade() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        jira.loseNextCreateReply()
        #expect(await world.call(run.id, "jira_create", ticket()).message != nil)
        #expect(try world.workspace.file.load().run(id: run.id)?.pendingWrites == ["jira_create/t1"], "kept as sent, on disk")
        let again = await world.call(run.id, "jira_create", ticket())
        #expect(again.value?["key"] == "PLUTO-101")
        #expect(jira.writes.count == 1, "the ticket made before is adopted, not made twice")
        #expect(jira.searches.last?.jql.contains("\"\(Self.label(run, "t1"))\"") == true)
        #expect(world.run(run.id)?.jiraCreated == ["t1": "PLUTO-101"] && world.run(run.id)?.pendingWrites.isEmpty == true)
    }

    /// A retry of a create that never reached Jira looks for it first, and makes it once nothing is found; read
    /// fresh after that search, so a Pause meanwhile makes nothing.
    @Test func aRetryLooksFirstAndAPauseDuringTheLookMakesNothing() async throws {
        let jira = FakeJira()
        var run = jiraRun(slice: true)
        run.state = .active
        let world = try makeWorld(run, jira: jira)
        jira.failNextCreateOnTheWay()
        #expect(await world.call(run.id, "jira_create", ticket()).message != nil)
        jira.searchHold.withLock { $0 = { @MainActor in world.workspace.mutate { $0.updateRun(id: run.id) { $0.intent = .paused } } } }
        #expect(await world.call(run.id, "jira_create", ticket()).message == "The person paused this operation. Wait until they resume it.")
        #expect(jira.writes.isEmpty)
        jira.searchHold.withLock { $0 = nil }
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.intent = nil } }
        #expect(await world.call(run.id, "jira_create", ticket()).value?["created"] == true)
        #expect(jira.writes.count == 1)
    }
}
