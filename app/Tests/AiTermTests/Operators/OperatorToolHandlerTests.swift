import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The operator's read and record tools (spec §6), answered from the workspace.
@MainActor @Suite struct OperatorToolHandlerTests {
    let pluto = JiraProjectRef(id: "1", key: "PLUTO", name: "Pluto", siteURL: URL(string: "https://acme.atlassian.net")!)
    let project: Project
    init() { project = OperatorServiceFixtures.project(jira: [pluto]) }

    /// The world these tests read Jira in. Its Jira budget is long: the fake answers at once, and a loaded machine (a full
    /// run's main-actor tests) must never turn a read that succeeds into Jira not answering. The budget's own test sets a
    /// short one of its own.
    func makeWorld(_ run: OperatorRun, jira: FakeJira? = nil) throws -> OperatorWorld {
        try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) { ports in
            if let jira { ports.jira = { jira } }
            ports.jiraSearchBudget = .seconds(600)
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
        #expect(await world.call(run.id, "resolve_question", ["key": "nope", "summary": "x"]).message == "No question nope in this broadcast.")
    }

    @Test func aDecisionIsWrittenOncePerKey() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        for _ in 0..<2 {
            _ = await world.call(run.id, "log_decision", ["key": "d1", "text": "Kept the old endpoint."])
        }
        #expect(world.run(run.id)?.decisions.map(\.text) == ["Kept the old endpoint."])
    }

    /// The Operator writes the summary once the broadcast is complete; the run keeps it with the time it came.
    @Test func writeSummaryIsRefusedBeforeComplete() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        #expect(await world.call(run.id, "write_summary", ["text": "Done."]).message == "The broadcast isn\u{2019}t complete yet.")
        #expect(world.run(run.id)?.summary == nil && world.run(run.id)?.summaryAt == nil)
    }

    @Test func writeSummaryStoresIt() async throws {
        let run = OperatorServiceFixtures.run(projects: [project], state: .complete)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) { $0.now = { at } }
        let answer = await world.call(run.id, "write_summary", ["text": "  Two tasks merged; one needed a retry.\n"])
        #expect(answer.value?["written"] == true)
        #expect(world.run(run.id)?.summary == "Two tasks merged; one needed a retry.", "surrounding whitespace is trimmed")
        #expect(world.run(run.id)?.summaryAt == at)
    }

    @Test func writeSummaryAgainReplacesIt() async throws {
        let run = OperatorServiceFixtures.run(projects: [project], state: .complete)
        let world = try makeWorld(run)
        _ = await world.call(run.id, "write_summary", ["text": "First."])
        _ = await world.call(run.id, "write_summary", ["text": "Second."])
        #expect(world.run(run.id)?.summary == "Second.")
    }

    @Test func writeSummaryNeedsText() async throws {
        let run = OperatorServiceFixtures.run(projects: [project], state: .complete)
        let world = try makeWorld(run)
        #expect(await world.call(run.id, "write_summary", [:]).message == "write_summary needs `text`.")
        #expect(await world.call(run.id, "write_summary", ["text": "  \n "]).message == "write_summary needs `text`.")
        #expect(world.run(run.id)?.summary == nil)
    }

    /// The summary is a change the Operator has seen: the call counts as its own news, so the wake does not echo it.
    @Test func writeSummaryIsAMutatingTool() {
        #expect(OperatorToolHandler.mutating.contains("write_summary"))
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

    /// AiTerm's own mistake is recorded once per key, with the task's key and branch and the app's version, and
    /// run_status lists it by key and title.
    @Test func reportSnagRecordsItOnceAndRunStatusListsIt() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PAY-240", state: .working)
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task])) { $0.appVersion = "0.28.0" }
        let snag = ["key": "stale-prompt", "title": "A prompt shows as working", "showed": "The row said working.",
                    "actual": "The worker was waiting on a prompt.", "workaround": "Answered it in its tab.",
                    "evidence": "Tab 2 showed Allow edits?", "task": "PAY-240"] as JSONValue
        let answer = await world.call(run.id, "report_snag", snag)
        #expect(answer.value?["snag"] == "stale-prompt" && answer.value?["recorded"] == true)
        _ = await world.call(run.id, "report_snag", ["key": "stale-prompt", "title": "Again", "showed": "s", "actual": "a", "workaround": "w"])

        let recorded = try #require(world.run(run.id)?.snags)
        #expect(recorded.count == 1)
        #expect(recorded.first?.title == "A prompt shows as working" && recorded.first?.evidence == "Tab 2 showed Allow edits?")
        #expect(recorded.first?.task == task.id && recorded.first?.taskKey == "PAY-240" && recorded.first?.branch == "feat/pay-240")
        #expect(recorded.first?.appVersion == "0.28.0")

        let listed = await world.call(run.id, "run_status").value?["run"]?["snags"]?.arrayValue
        #expect(listed == [["key": "stale-prompt", "title": "A prompt shows as working"]])
        let missing = await world.call(run.id, "report_snag", ["key": "x", "title": "t", "showed": "s", "workaround": "w"])
        #expect(missing.message == "report_snag needs `actual`.")
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

    /// A search Jira holds for 40 s is answered inside the daemon's wait for the app (`OperatorTiming.operatorRequestTimeout`),
    /// with why, rather than left to the daemon's "AiTerm isn't answering". The refusal is the budget's, given while the
    /// search was still held; no wall clock is checked, since a full run's main-actor tests can delay any main-actor answer.
    @Test func aSlowJiraSearchAnswersBeforeTheDaemonGivesUp() async throws {
        #expect(OperatorTiming.jiraSearchBudget == 20 && OperatorTiming.jiraSearchBudget < OperatorTiming.operatorRequestTimeout)
        let jira = FakeJira()
        jira.searchHold.withLock { $0 = { try? await Task.sleep(for: .seconds(40)) } }
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run])) { ports in
            #expect(ports.jiraSearchBudget == .seconds(OperatorTiming.jiraSearchBudget))
            ports.jira = { jira }
            ports.jiraSearchBudget = .seconds(1)
        }
        let answer = await world.call(run.id, "jira_search", ["jql": "project = PLUTO"])
        #expect(answer.message == "Jira didn’t answer within 1 s; try a narrower JQL.")
        #expect(jira.searches.count == 1)
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

    // -- Jira boards and sprints (spec §L) ------------------------------------------------------------

    /// A Jira that has a scrum board with sprints 41 (active) and 42 (future) in PLUTO, a kanban board in WEB, and a scrum
    /// board with sprint 99 in PAY, which the broadcast does not have.
    func agileJira() -> FakeJira {
        let jira = FakeJira()
        jira.put(boards: [JiraBoard(id: 7, name: "Pluto board", type: "scrum")],
                 sprints: [JiraSprint(id: 41, name: "Sprint 41", state: "active", startDate: "2026-10-12", endDate: "2026-10-26", boardId: 7),
                           JiraSprint(id: 42, name: "Sprint 42", state: "future", startDate: nil, endDate: nil, boardId: 7)],
                 columns: [JiraColumn(name: "To Do", statuses: ["Open"]), JiraColumn(name: "Done", statuses: ["Done"])], in: "PLUTO")
        jira.put(boards: [JiraBoard(id: 9, name: "Web flow", type: "kanban")], columns: [JiraColumn(name: "Doing", statuses: ["In Progress"])], in: "WEB")
        jira.put(boards: [JiraBoard(id: 11, name: "Pay board", type: "scrum")],
                 sprints: [JiraSprint(id: 99, name: "Sprint 99", state: "active", startDate: nil, endDate: nil, boardId: 11)], in: "PAY")
        return jira
    }

    @Test func jiraBoardNeedsNoSliceAndReadsOnlyTheBroadcastsProjects() async throws {
        let jira = agileJira()
        let run = jiraRun(slice: false)
        let world = try makeWorld(run, jira: jira)
        let answer = try #require(await world.call(run.id, "jira_board").value?.arrayValue)
        #expect(answer.map { $0["project"] } == ["PLUTO", "WEB"], "PAY is not the broadcast's")
        let pluto = try #require(answer.first?["boards"]?.arrayValue?.first)
        #expect(pluto["id"] == 7 && pluto["name"] == "Pluto board" && pluto["type"] == "scrum")
        #expect(pluto["sprints"]?.arrayValue?.map { $0["name"] } == ["Sprint 41", "Sprint 42"])
        #expect(pluto["sprints"]?.arrayValue?.first?["state"] == "active" && pluto["sprints"]?.arrayValue?.first?["endDate"] == "2026-10-26")
        #expect(pluto["columns"]?.arrayValue?.first?["name"] == "To Do" && pluto["columns"]?.arrayValue?.first?["statuses"] == ["Open"])
        let web = try #require(answer.last?["boards"]?.arrayValue?.first)
        #expect(web["sprints"] == [] && web["columns"]?.arrayValue?.count == 1, "a kanban board has columns and no sprints")
        #expect(world.run(run.id)?.leftForYou.isEmpty == true)
    }

    /// A team-managed scrum board is `simple` in Jira Cloud, and has sprints.
    @Test func aSimpleBoardsSprintTakesTickets() async throws {
        let jira = agileJira()
        jira.put(boards: [JiraBoard(id: 13, name: "Web team board", type: "simple")],
                 sprints: [JiraSprint(id: 61, name: "Web sprint 1", state: "active", startDate: nil, endDate: nil, boardId: 13)], in: "WEB")
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        let seen = try #require(await world.call(run.id, "jira_board").value?.arrayValue?.last?["boards"]?.arrayValue?.last)
        #expect(seen["sprints"]?.arrayValue?.map { $0["name"] } == ["Web sprint 1"])
        #expect(await world.call(run.id, "jira_sprint", ["key": "s1", "tickets": ["WEB-2"], "sprint": 61]).value?["sprinted"] == true)
        #expect(jira.writes == [.sprint(tickets: ["WEB-2"], sprint: 61)])
    }

    @Test func aBoardThatHasNoSprintsReadsNoneAndDoesNotFailTheRead() async throws {
        let jira = agileJira()
        jira.refuseSprints(of: 7)
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        let answer = try #require(await world.call(run.id, "jira_board").value?.arrayValue)
        #expect(answer.first?["boards"]?.arrayValue?.first?["sprints"] == [])
        #expect(answer.first?["boards"]?.arrayValue?.first?["columns"]?.arrayValue?.count == 2)
        #expect(await world.call(run.id, "jira_sprint", ["key": "s1", "tickets": ["PLUTO-1"], "sprint": 41]).message
                == "Sprint 41 isn’t an active or future sprint on a board of this broadcast’s Jira projects: PLUTO, WEB.")
        #expect(jira.writes.isEmpty)
    }

    @Test func jiraBoardWithoutJiraSaysWhere() async throws {
        let run = jiraRun(slice: true)
        let world = try makeWorld(run)
        #expect(await world.call(run.id, "jira_board").message == "Jira isn’t connected in AiTerm’s Settings › Integrations.")
    }

    @Test func jiraSprintNeedsTheSlice() async throws {
        let jira = agileJira()
        let run = jiraRun(slice: false)
        let world = try makeWorld(run, jira: jira)
        let off = "The Jira slice is off for this broadcast."
        #expect(await world.call(run.id, "jira_sprint", ["key": "s1", "tickets": ["PLUTO-1", "WEB-2"], "sprint": 41]).message == off)
        #expect(await world.call(run.id, "jira_sprint", ["key": "s2", "tickets": ["PLUTO-1"], "sprint": "backlog"]).message == off)
        #expect(jira.writes.isEmpty)
        #expect(world.run(run.id)?.leftForYou == ["Put PLUTO-1, WEB-2 in sprint 41: the Jira slice is off.",
                                                  "Move PLUTO-1 to the backlog: the Jira slice is off."])
    }

    @Test func jiraSprintPutsTicketsInASprintOrOnTheBacklog() async throws {
        let jira = agileJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        let added = await world.call(run.id, "jira_sprint", ["key": "s1", "tickets": ["pluto-1", "WEB-2", "PLUTO-1"], "sprint": 41])
        #expect(added.value?["sprinted"] == true && added.value?["sprint"] == "41" && added.value?["tickets"] == ["PLUTO-1", "WEB-2"])
        #expect(await world.call(run.id, "jira_sprint", ["key": "s2", "tickets": ["PLUTO-3"], "sprint": "42"]).value?["sprinted"] == true, "an id may come as text")
        let back = await world.call(run.id, "jira_sprint", ["key": "s3", "tickets": ["PLUTO-1"], "sprint": "Backlog"])
        #expect(back.value?["sprinted"] == true && back.value?["sprint"] == "backlog")
        #expect(jira.writes == [.sprint(tickets: ["PLUTO-1", "WEB-2"], sprint: 41), .sprint(tickets: ["PLUTO-3"], sprint: 42), .backlog(tickets: ["PLUTO-1"])],
                "each ticket once, upper-cased")
        #expect(world.run(run.id)?.leftForYou.isEmpty == true)
    }

    @Test func aSprintOfAnotherProjectIsRefused() async throws {
        let jira = agileJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        let nowhere = "Sprint 99 isn’t an active or future sprint on a board of this broadcast’s Jira projects: PLUTO, WEB."
        #expect(await world.call(run.id, "jira_sprint", ["key": "s1", "tickets": ["PLUTO-1"], "sprint": 99]).message == nowhere)
        #expect(await world.call(run.id, "jira_sprint", ["key": "s2", "tickets": ["PLUTO-1"], "sprint": 12345]).message
                == "Sprint 12345 isn’t an active or future sprint on a board of this broadcast’s Jira projects: PLUTO, WEB.")
        #expect(await world.call(run.id, "jira_sprint", ["key": "s3", "tickets": ["PLUTO-1"], "sprint": "next"]).message
                == "jira_sprint’s `sprint` is a sprint’s id from jira_board, or \"backlog\".")
        #expect(jira.writes.isEmpty && world.run(run.id)?.jiraSprinted.isEmpty == true)
    }

    @Test func aTicketOutOfScopeIsRefused() async throws {
        let jira = agileJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        let outside = "isn’t in this broadcast’s Jira projects: PLUTO, WEB."
        #expect(await world.call(run.id, "jira_sprint", ["key": "s1", "tickets": ["PLUTO-1", "PAY-9"], "sprint": 41]).message == "PAY-9 \(outside)")
        #expect(await world.call(run.id, "jira_sprint", ["key": "s2", "tickets": ["PAY-9"], "sprint": "backlog"]).message == "PAY-9 \(outside)")
        #expect(await world.call(run.id, "jira_sprint", ["key": "s3", "tickets": [], "sprint": 41]).message == "jira_sprint needs `tickets`, the keys to move.")
        #expect(await world.call(run.id, "jira_sprint", ["key": "s4", "tickets": ["PLUTO-1"]]).message == "jira_sprint needs `sprint`.")
        #expect(jira.writes.isEmpty)
        let off = jiraRun(slice: false)
        let offWorld = try makeWorld(off, jira: jira)
        #expect(await offWorld.call(off.id, "jira_sprint", ["key": "s1", "tickets": ["PAY-9"], "sprint": 41]).message == "PAY-9 \(outside)")
        #expect(offWorld.run(off.id)?.leftForYou.isEmpty == true)
    }

    @Test func jiraSprintIsSafeToRepeat() async throws {
        let jira = agileJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        let first = await world.call(run.id, "jira_sprint", ["key": "s1", "tickets": ["PLUTO-1"], "sprint": 41])
        let again = await world.call(run.id, "jira_sprint", ["key": "s1", "tickets": ["PLUTO-1", "PLUTO-2"], "sprint": 41])
        #expect(first.value?["sprinted"] == true && again.value?["sprinted"] == false && again.value?["sprint"] == "41")
        #expect(jira.writes.count == 1, "one write for one key")
        #expect(world.run(run.id)?.jiraSprinted == ["s1": "41"])
        #expect(try world.workspace.file.load().run(id: run.id)?.jiraSprinted == ["s1": "41"])
        // A failed write records nothing: the same key may try again.
        jira.failWrites()
        #expect(await world.call(run.id, "jira_sprint", ["key": "s2", "tickets": ["PLUTO-1"], "sprint": 42]).message == "Jira returned an error (HTTP 500). Try again.")
        #expect(world.run(run.id)?.jiraSprinted == ["s1": "41"])
        jira.failWrites(false)
        #expect(await world.call(run.id, "jira_sprint", ["key": "s2", "tickets": ["PLUTO-1"], "sprint": 42]).value?["sprinted"] == true)
    }

    @Test func jiraSprintIsCheckedAgainJustBeforeTheWrite() async throws {
        let jira = agileJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        // The slice is turned off after the sprint is read and before the write.
        jira.beforeSprintWrite.withLock { $0 = { @Sendable in await MainActor.run { world.workspace.mutate { $0.updateRun(id: run.id) { $0.profile.slices.jira = false } } } } }
        #expect(await world.call(run.id, "jira_sprint", ["key": "s1", "tickets": ["PLUTO-1"], "sprint": 41]).message == "The Jira slice is off for this broadcast.")
        #expect(jira.writes.isEmpty && world.run(run.id)?.jiraSprinted.isEmpty == true)
    }

    // -- jira_edit and jira_comment (spec §L) --------------------------------------------------------

    func edit(_ ticket: String = "PLUTO-1", _ more: [String: JSONValue] = ["summary": "A better title"], key: String = "e1") -> JSONValue {
        .object(["key": .string(key), "ticket": .string(ticket)].merging(more) { _, new in new })
    }

    @Test func jiraEditChangesTheNamedFields() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        let answer = await world.call(run.id, "jira_edit", edit("pluto-1", [
            "summary": "A better title", "description": "Why.", "labelsAdd": ["web", " "], "labelsRemove": ["old"], "priority": "High",
            "fixVersions": ["1.4"], "assignee": "Me"]))
        #expect(answer.value?["edited"] == true && answer.value?["ticket"] == "PLUTO-1")
        #expect(jira.writes == [.edit(key: "PLUTO-1", fields: JiraEdit(summary: "A better title", description: "Why.", labelsAdd: ["web"],
                                                                      labelsRemove: ["old"], priority: "High", fixVersions: ["1.4"], assignee: .me))])
        let named = await world.call(run.id, "jira_edit", edit("PLUTO-2", ["assignee": "sofie@example.com", "fixVersions": [], "description": ""], key: "e2"))
        #expect(named.value?["edited"] == true)
        #expect(jira.writes.last == .edit(key: "PLUTO-2", fields: JiraEdit(description: "", fixVersions: [], assignee: .query("sofie@example.com"))))
        _ = await world.call(run.id, "jira_edit", edit("PLUTO-3", ["assignee": "none"], key: "e3"))
        #expect(jira.writes.last == .edit(key: "PLUTO-3", fields: JiraEdit(assignee: .unassigned)))
    }

    @Test func anEmptyEditIsRefused() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        let needs = "jira_edit needs at least one of summary, description, labelsAdd, labelsRemove, priority, fixVersions or assignee."
        #expect(await world.call(run.id, "jira_edit", edit("PLUTO-1", [:])).message == needs)
        #expect(await world.call(run.id, "jira_edit", edit("PLUTO-1", ["summary": " ", "labelsAdd": [], "priority": " "])).message == needs)
        #expect(await world.call(run.id, "jira_edit", edit("PLUTO-1", ["labelsAdd": "web"])).message == "jira_edit’s `labelsAdd` is a list of text.")
        #expect(jira.writes.isEmpty)
    }

    /// `jira_edit` reads no `key`: a call without one edits.
    @Test func anEditWithoutAKeyEdits() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        #expect(await world.call(run.id, "jira_edit", ["ticket": "PLUTO-1", "summary": "s"]).value == ["ticket": "PLUTO-1", "edited": true])
        #expect(jira.writes.count == 1)
    }

    @Test func jiraEditAndCommentNeedTheSlice() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: false)
        let world = try makeWorld(run, jira: jira)
        let off = "The Jira slice is off for this broadcast."
        #expect(await world.call(run.id, "jira_edit", edit()).message == off)
        #expect(await world.call(run.id, "jira_comment", ["key": "c1", "ticket": "PLUTO-1", "body": "Done."]).message == off)
        #expect(jira.writes.isEmpty && world.run(run.id)?.jiraCommented.isEmpty == true)
        #expect(world.run(run.id)?.leftForYou == ["Edit PLUTO-1: the Jira slice is off.", "Comment on PLUTO-1: the Jira slice is off."])
    }

    @Test func stayInScope() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        let outside = "PAY-9 isn’t in this broadcast’s Jira projects: PLUTO, WEB."
        #expect(await world.call(run.id, "jira_edit", edit("PAY-9")).message == outside)
        #expect(await world.call(run.id, "jira_comment", ["key": "c1", "ticket": "PAY-9", "body": "Hi."]).message == outside)
        #expect(await world.call(run.id, "jira_edit", edit("not a key")).message == "not a key isn’t a Jira ticket key like PLUTO-231.")
        #expect(jira.writes.isEmpty)
        let off = jiraRun(slice: false)
        let offWorld = try makeWorld(off, jira: jira)
        #expect(await offWorld.call(off.id, "jira_edit", edit("PAY-9")).message == outside)
        #expect(offWorld.run(off.id)?.leftForYou.isEmpty == true, "a ticket outside is no slice matter")
    }

    @Test func jiraCommentPostsAndIsSafeToRepeat() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        let first = await world.call(run.id, "jira_comment", ["key": "c1", "ticket": "pluto-1", "body": " Shipped in 1.4. "])
        #expect(first.value?["commented"] == true && first.value?["commentId"] == "c1" && first.value?["ticket"] == "PLUTO-1")
        let again = await world.call(run.id, "jira_comment", ["key": "c1", "ticket": "PLUTO-2", "body": "Another."])
        #expect(again.value?["commented"] == false && again.value?["commentId"] == "c1")
        #expect(jira.writes == [.comment(key: "PLUTO-1", body: "Shipped in 1.4.")], "one comment for one key")
        #expect(world.run(run.id)?.pendingWrites.isEmpty == true)
        #expect(world.run(run.id)?.jiraCommented == ["c1": "c1"])
        #expect(try world.workspace.file.load().run(id: run.id)?.jiraCommented == ["c1": "c1"])
        // A failed post records nothing: the same key may try again.
        jira.failWrites()
        #expect(await world.call(run.id, "jira_comment", ["key": "c2", "ticket": "PLUTO-1", "body": "Two."]).message == "Jira returned an error (HTTP 500). Try again.")
        #expect(world.run(run.id)?.jiraCommented == ["c1": "c1"])
        jira.failWrites(false)
        #expect(await world.call(run.id, "jira_comment", ["key": "c2", "ticket": "PLUTO-1", "body": "Two."]).value?["commented"] == true)
        #expect(await world.call(run.id, "jira_comment", ["key": "c3", "ticket": "PLUTO-1"]).message == "jira_comment needs `body`.")
    }

    /// A comment whose POST landed and whose answer was lost is found again by its tag, and posted once.
    @Test func aCommentWhoseReplyWasLostIsFoundNotPostedAgain() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        let call: JSONValue = ["key": "c1", "ticket": "PLUTO-1", "body": "Shipped."]
        jira.loseNextCommentReply()
        #expect(await world.call(run.id, "jira_comment", call).message != nil)
        #expect(jira.comments.count == 1 && world.run(run.id)?.pendingWrites == ["jira_comment/c1"], "kept pending while it may have landed")
        #expect(world.run(run.id)?.jiraCommented.isEmpty == true)
        let again = await world.call(run.id, "jira_comment", call)
        #expect(again.value?["commented"] == false && again.value?["commentId"] == "c1")
        #expect(jira.comments.count == 1, "one comment, found by its tag")
        #expect(world.run(run.id)?.pendingWrites.isEmpty == true && world.run(run.id)?.jiraCommented == ["c1": "c1"])
        #expect(jira.comments.first?.tag == OperatorToolHandler.createLabel(run: run.id, key: "c1"), "tagged with the run-scoped hash of its key")
    }

    /// A pending comment that is not on the ticket never landed: the retry posts it.
    @Test func aPendingCommentThatIsNotThereIsPosted() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        jira.failWrites()
        #expect(await world.call(run.id, "jira_comment", ["key": "c1", "ticket": "PLUTO-1", "body": "Hi."]).message == "Jira returned an error (HTTP 500). Try again.")
        #expect(world.run(run.id)?.pendingWrites == ["jira_comment/c1"], "a 500 may have landed")
        jira.failWrites(false)
        #expect(await world.call(run.id, "jira_comment", ["key": "c1", "ticket": "PLUTO-1", "body": "Hi."]).value?["commented"] == true)
        #expect(jira.comments.count == 1 && world.run(run.id)?.pendingWrites.isEmpty == true)
        // A refusal made nothing, so nothing stays pending.
        jira.refuseWrites("bad")
        _ = await world.call(run.id, "jira_comment", ["key": "c2", "ticket": "PLUTO-1", "body": "Hi."])
        #expect(world.run(run.id)?.pendingWrites.isEmpty == true)
    }

    /// Two calls with one key that overlap post once: the second is told the first is still posting.
    @Test func twoOverlappingCommentsWithOneKeyPostOnce() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        let (gate, release) = AsyncStream<Void>.makeStream()
        let entered = Mutex(false)
        jira.beforeEditWrite.withLock { $0 = { @Sendable in entered.withLock { $0 = true }; for await _ in gate { break } } }
        let call: JSONValue = ["key": "c1", "ticket": "PLUTO-1", "body": "Once."]
        let first = Task { @MainActor in await world.call(run.id, "jira_comment", call) }
        while !entered.withLock({ $0 }) { await Task.yield() }
        #expect(await world.call(run.id, "jira_comment", call).message == "jira_comment with this key is still posting: call it again for its result.")
        jira.beforeEditWrite.withLock { $0 = nil }
        release.yield(())
        #expect(await first.value.value?["commented"] == true)
        #expect(jira.comments.count == 1)
        #expect(await world.call(run.id, "jira_comment", call).value?["commented"] == false)
    }

    @Test func jiraEditAndCommentAreCheckedAgainJustBeforeTheWrite() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        jira.beforeEditWrite.withLock { $0 = { @Sendable in await MainActor.run { world.workspace.mutate { $0.updateRun(id: run.id) { $0.profile.slices.jira = false } } } } }
        let off = "The Jira slice is off for this broadcast."
        #expect(await world.call(run.id, "jira_edit", edit()).message == off)
        #expect(await world.call(run.id, "jira_comment", ["key": "c1", "ticket": "PLUTO-1", "body": "Hi."]).message == off)
        #expect(jira.writes.isEmpty && world.run(run.id)?.jiraCommented.isEmpty == true)
    }

    @Test func jiraEditAndCommentWithoutJiraSayWhere() async throws {
        let run = jiraRun(slice: true)
        let world = try makeWorld(run)
        let none = "Jira isn’t connected in AiTerm’s Settings › Integrations."
        #expect(await world.call(run.id, "jira_edit", edit()).message == none)
        #expect(await world.call(run.id, "jira_comment", ["key": "c1", "ticket": "PLUTO-1", "body": "Hi."]).message == none)
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
        #expect(await world.call(run.id, "finish_task", ["task": "x"]).message == "No task x in this broadcast.")
        #expect(await world.call(run.id, "merge_everything").message == "AiTerm has no tool called merge_everything.")
        #expect(await world.call(UUID(), "run_status").message == "This broadcast is no longer in AiTerm.")
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

    /// A worker's prompt is AiTerm's to close, when its worker leaves the prompt; a merge on the host is the person's to
    /// decide, so the Operator closes that question once the person has answered in its chat.
    @Test func aPromptIsAiTermsToCloseAndAMergeOnTheHostIsClosedOnceThePersonAnswers() async throws {
        var run = OperatorServiceFixtures.run(projects: [project])
        let prompted = workingTask(in: run), merged = workingTask(in: run, key: "T2")
        let prompt = OperatorQuestion(id: "prompt-\(prompted.id.uuidString)-1", text: "Claude asks to run npm install", task: prompted.id, askedAt: Date(timeIntervalSince1970: 0))
        let merge = OperatorQuestion(id: "merged-on-host-\(merged.id.uuidString)", text: "The host merged it.", task: merged.id, askedAt: Date(timeIntervalSince1970: 0))
        run.questions = [prompt, merge]
        let world = try makeWorld(run, tasks: [prompted, merged])
        world.workspace.mutate { state in
            for id in [prompted.id, merged.id] { state.updateOperated(id) { $0.flags.insert(.waitingOnYou) } }
        }
        let refused = await world.call(run.id, "resolve_question", ["key": .string(prompt.id), "summary": "Done."])
        #expect(refused.message == "\(prompt.id) is a worker’s prompt: AiTerm closes its question itself once the worker leaves the prompt. If it looks stale, record it with report_snag.")
        let resolved = await world.call(run.id, "resolve_question", ["key": .string(merge.id), "summary": "Go on without PAY-14."])
        #expect(resolved.value?["open"] == false)
        #expect(world.run(run.id)?.questions.map(\.resolution) == [nil, "Go on without PAY-14."])
        #expect(world.task(prompted.id)?.operated?.flags.contains(.waitingOnYou) == true)
        #expect(world.task(merged.id)?.operated?.flags.contains(.waitingOnYou) == false, "its last open question")
    }

    @Test func askYouRefusesAiTermsQuestionKeys() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        for key in ["prompt-mine", "merged-on-host-mine", "gate-mine"] {
            #expect(await world.call(run.id, "ask_you", ["key": .string(key), "question": "Q?"]).message
                    == "Keys starting with “prompt-”, “merged-on-host-” or “gate-” are AiTerm’s own questions. Choose another key.")
        }
        #expect(world.run(run.id)?.questions.isEmpty == true)
    }

    @Test func askYouOnATaskSaysWhatThatDoes() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let task = workingTask(in: run)
        let world = try makeWorld(run, tasks: [task])
        let onTask = await world.call(run.id, "ask_you", ["key": "a", "question": "Stuck?", "task": "T1"])
        #expect(onTask.value?["note"] == "Your row in the sidebar now shows waiting on the person, naming this task, and they answer in this chat. The task waits: it isn't ready to accept and isn't watched for stalls until you resolve the question.")
        #expect(await world.call(run.id, "ask_you", ["key": "b", "question": "Which scope?"]).value?["note"] == nil)
    }

    /// A repeat of a key already resolved says so, and not that the task now waits on the person.
    @Test func askYouAgainOnAResolvedQuestionSaysNothingOfWaiting() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let task = workingTask(in: run)
        let world = try makeWorld(run, tasks: [task])
        _ = await world.call(run.id, "ask_you", ["key": "a", "question": "Stuck?", "task": "T1"])
        _ = await world.call(run.id, "resolve_question", ["key": "a", "summary": "No."])
        let again = await world.call(run.id, "ask_you", ["key": "a", "question": "Stuck?", "task": "T1"])
        #expect(again.value?["open"] == false)
        #expect(again.value?["note"] == nil)
        #expect(world.task(task.id)?.operated?.flags.contains(.waitingOnYou) == false)
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
        let ended = "This broadcast has ended; its tools no longer act."
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
        #expect(answer.message == "None of this broadcast’s projects is linked to a Jira project, so there is nothing jira_search may search.")
        #expect(jira.searches.isEmpty)
    }

    @Test func aMissingArgumentOrAnUnknownTaskIsSaidPlainly() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        #expect(await world.call(run.id, "ask_you", ["key": "k"]).message == "ask_you needs `question`.")
        #expect(await world.call(run.id, "ask_you", ["key": "k", "question": "   "]).message == "ask_you needs `question`.")
        #expect(await world.call(run.id, "jira_search").message == "jira_search needs `jql`.")
        #expect(await world.call(run.id, "log_decision", ["key": "d", "text": "t", "task": "nope"]).message == "No task nope in this broadcast.")
        #expect(await world.call(run.id, "ask_you", ["key": "k", "question": "Q?", "task": "nope"]).message == "No task nope in this broadcast.")
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
        #expect(act("message_task", .inReview) == .relayingFeedback)
        #expect(act("reply_thread", .inReview) == .relayingFeedback)
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
        #expect(OperatorToolHandler.actsOnBroadcast["report_snag"] == nil, "it files nothing")
    }

    // MARK: - Gate C: Jira writes wait while the operation does not run, and a lost answer makes no second ticket

    /// The label `jira_create` gives the ticket for `key` in `run`.
    static func label(_ run: OperatorRun, _ key: String) -> String {
        // All these fixtures use t1; this is its independently calculated SHA-256 digest.
        precondition(key == "t1")
        return "aiterm-v2-\(run.id.uuidString.lowercased())-628b49d96dcde97a430dd4f597705899e09a968f793491e4b704cae33a40dc02"
    }

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
        #expect(await world.call(run.id, "jira_move", ["key": "PLUTO-231", "status": "Done"]).message == "The person paused this broadcast. Wait until they resume it.")
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

    @Test func collidingRawKeysRecoverTheirOwnTickets() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        func args(_ key: String) -> JSONValue {
            ["key": .string(key), "project": "PLUTO", "type": "Task", "summary": .string(key), "description": "Work"]
        }
        jira.loseNextCreateReply()
        #expect(await world.call(run.id, "jira_create", args("a/b")).message != nil)
        jira.loseNextCreateReply()
        #expect(await world.call(run.id, "jira_create", args("a_b")).message != nil)
        let second = await world.call(run.id, "jira_create", args("a_b"))
        let first = await world.call(run.id, "jira_create", args("a/b"))
        #expect(first.value?["key"] == "PLUTO-101")
        #expect(second.value?["key"] == "PLUTO-102")
        #expect(jira.writes.count == 2)
    }

    @Test func runsWithTheSameOldPrefixRecoverTheirOwnTickets() async throws {
        let jira = FakeJira()
        var first = jiraRun(slice: true), second = jiraRun(slice: true)
        first.id = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
        second.id = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000002")!
        let one = try makeWorld(first, jira: jira), two = try makeWorld(second, jira: jira)
        jira.loseNextCreateReply()
        _ = await one.call(first.id, "jira_create", ticket())
        jira.loseNextCreateReply()
        _ = await two.call(second.id, "jira_create", ticket())
        #expect(await one.call(first.id, "jira_create", ticket()).value?["key"] == "PLUTO-101")
        #expect(await two.call(second.id, "jira_create", ticket()).value?["key"] == "PLUTO-102")
        #expect(jira.writes.count == 2)
    }

    @Test func canonicallyEquivalentKeysRecoverTheSameTicketAfterRestart() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        func args(_ key: String) -> JSONValue {
            ["key": .string(key), "project": "PLUTO", "type": "Task", "summary": "Work", "description": "Work"]
        }
        jira.loseNextCreateReply()
        _ = await world.call(run.id, "jira_create", args("caf\u{e9}"))
        let restarted = try OperatorWorld(try world.workspace.file.load()) { $0.jira = { jira } }
        #expect(await restarted.call(run.id, "jira_create", args("cafe\u{301}")).value?["key"] == "PLUTO-101")
        #expect(jira.writes.count == 1)
    }

    @Test func retryWithAnotherAllowedProjectRecoversTheOriginalWrite() async throws {
        let jira = FakeJira()
        var run = jiraRun(slice: true)
        run.jiraProjectKeys = ["PLUTO", "WEB"]
        let world = try makeWorld(run, jira: jira)
        jira.loseNextCreateReply()
        _ = await world.call(run.id, "jira_create", ticket())
        #expect(await world.call(run.id, "jira_create", ticket(["project": "WEB"])).value?["key"] == "PLUTO-101")
        #expect(jira.writes.count == 1)
    }

    @Test func collidingFindKeysRecoverTheirOwnTickets() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        for key in ["a/b", "a_b"] {
            jira.loseNextCreateReply()
            _ = await world.call(run.id, "report_find", ["key": .string(key), "title": .string(key), "why": "Off brief"])
        }
        for key in ["a_b", "a/b"] {
            _ = await world.call(run.id, "report_find", ["key": .string(key), "title": .string(key), "why": "Off brief"])
        }
        #expect(world.run(run.id)?.finds.map(\.ticket) == ["PLUTO-101", "PLUTO-102"])
        #expect(jira.writes.count == 2)
    }

    @Test func legacyPendingCreateIsRetainedForManualReconciliationAfterRestart() async throws {
        let jira = FakeJira()
        var run = jiraRun(slice: true)
        run.pendingWrites = ["jira_create/t1"]
        let world = try makeWorld(run, jira: jira)
        #expect(world.workspace.flush())
        let restarted = try OperatorWorld(try world.workspace.file.load()) { $0.jira = { jira } }
        let answer = await restarted.call(run.id, "jira_create", ticket())
        #expect(answer.message?.contains("older Jira label") == true)
        #expect(jira.writes.isEmpty && jira.searches.isEmpty)
        #expect(restarted.run(run.id)?.pendingWrites == ["jira_create/t1"])
    }

    @Test func multipleRecoveryMatchesAreRefusedWithoutAnotherWrite() async throws {
        let jira = FakeJira(tickets: [
            JiraTicket(key: "PLUTO-101", summary: "Work", description: nil, issueType: "Task", status: "Open", url: "https://acme.atlassian.net/browse/PLUTO-101"),
            JiraTicket(key: "PLUTO-102", summary: "Work", description: nil, issueType: "Task", status: "Open", url: "https://acme.atlassian.net/browse/PLUTO-102")])
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        jira.failNextCreateOnTheWay()
        _ = await world.call(run.id, "jira_create", ticket())
        #expect(await world.call(run.id, "jira_create", ticket()).message != nil)
        #expect(jira.writes.isEmpty)
        #expect(world.run(run.id)?.jiraCreated.isEmpty == true)
    }

    @Test func aCreateWhoseAnswerWasLostAdoptsTheTicketItMade() async throws {
        let jira = FakeJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        jira.loseNextCreateReply()
        #expect(await world.call(run.id, "jira_create", ticket()).message != nil)
        #expect(try world.workspace.file.load().run(id: run.id)?.pendingWrites == ["jira_create_v2/t1"], "kept as sent, on disk")
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
        #expect(await world.call(run.id, "jira_create", ticket()).message == "The person paused this broadcast. Wait until they resume it.")
        #expect(jira.writes.isEmpty)
        jira.searchHold.withLock { $0 = nil }
        world.workspace.mutate { $0.updateRun(id: run.id) { $0.intent = nil } }
        #expect(await world.call(run.id, "jira_create", ticket()).value?["created"] == true)
        #expect(jira.writes.count == 1)
    }
}

extension OperatorToolHandlerTests {
    @Test func selectedJiraProjectsAreVisibleAndSearchableWithoutRepositories() async throws {
        var run = OperatorServiceFixtures.run(projects: [])
        run.jiraProjectKeys = ["PAY"]
        let jira = FakeJira()
        let world = try makeWorld(run, jira: jira)
        #expect(await world.call(run.id, "run_status").value?["run"]?["jiraProjectKeys"] == ["PAY"])
        let answer = await world.call(run.id, "jira_search", ["jql": "status = Open ORDER BY updated DESC"])
        #expect(answer.message == nil)
        #expect(jira.searches.last?.projects == ["PAY"])
        #expect(jira.searches.last?.jql == "status = Open ORDER BY updated DESC")
    }

    @Test func selectedAndLinkedJiraProjectsAreSearchedTogether() async throws {
        var run = OperatorServiceFixtures.run(projects: [project])
        run.jiraProjectKeys = ["PAY"]
        let jira = FakeJira()
        let world = try makeWorld(run, jira: jira)
        _ = await world.call(run.id, "jira_search", ["jql": "status = Open"])
        #expect(jira.searches.last?.projects == ["PLUTO", "PAY"], "the linked project keeps its own site check beside the chosen one")
    }

    @Test func leftForYouIsRecordOnlyAndIdempotentAfterRestart() async throws {
        let run = OperatorServiceFixtures.run(projects: [project])
        let world = try makeWorld(run)
        _ = await world.call(run.id, "leave_for_you", ["key": "push", "text": "Push main: merged locally."])
        #expect(world.workspace.flush())
        let restarted = try OperatorWorld(try world.workspace.file.load())
        _ = await restarted.call(run.id, "leave_for_you", ["key": "push", "text": "Another text."])
        #expect(restarted.run(run.id)?.leftForYou == ["Push main: merged locally."])
        #expect(restarted.state.tasks.isEmpty && restarted.run(run.id)?.questions.isEmpty == true)
    }

    @Test func filingAFindRecoversTheLabelAfterALostReply() async throws {
        var run = OperatorServiceFixtures.run(projects: [project])
        run.profile.slices.jira = true
        run.jiraProjectKeys = ["PLUTO"]
        let jira = FakeJira()
        jira.loseNextCreateReply()
        let world = try makeWorld(run, jira: jira)
        let args: JSONValue = ["key": "leak", "title": "Token leak", "why": "Logs expose it."]
        _ = await world.call(run.id, "report_find", args)
        _ = await world.call(run.id, "report_find", args)
        #expect(jira.writes.count == 1)
        #expect(jira.labels.values.first == [OperatorToolHandler.createLabel(run: run.id, key: "find/leak")])
        #expect(world.run(run.id)?.finds.first?.ticket != nil)
        #expect(world.run(run.id)?.pendingWrites.isEmpty == true)
    }
}

extension OperatorToolHandlerTests {
    @Test func aFindKeyDoesNotReuseAnIndependentJiraCreateTicket() async throws {
        var run = OperatorServiceFixtures.run(projects: [project])
        run.profile.slices.jira = true
        run.jiraProjectKeys = ["PLUTO"]
        let jira = FakeJira()
        let world = try makeWorld(run, jira: jira)
        let made = await world.call(run.id, "jira_create", ["key": "leak", "project": "PLUTO", "type": "Task",
                                                           "summary": "Planned work", "description": "In the brief."])
        _ = await world.call(run.id, "report_find", ["key": "leak", "title": "Token leak", "why": "Off brief."])
        #expect(jira.writes.count == 2)
        #expect(world.run(run.id)?.finds.first?.ticket != made.value?["key"]?.stringValue)
        #expect(world.run(run.id)?.jiraCreated["leak"] == made.value?["key"]?.stringValue)
        #expect(world.run(run.id)?.jiraCreated["find/leak"] == world.run(run.id)?.finds.first?.ticket)
    }
}

extension OperatorToolHandlerTests {
    @Test func publicJiraCreateCannotUseTheInternalFindKeyNamespace() async throws {
        var run = OperatorServiceFixtures.run(projects: [project])
        run.profile.slices.jira = true
        run.jiraProjectKeys = ["PLUTO"]
        let jira = FakeJira()
        let world = try makeWorld(run, jira: jira)
        let args: JSONValue = ["key": "find/leak", "project": "PLUTO", "type": "Task",
                               "summary": "Independent ticket", "description": "In the brief."]
        let refusal = "jira_create keys starting with “find/” are reserved for off-brief finds. Choose another key."
        #expect(await world.call(run.id, "jira_create", args).message == refusal)
        #expect(jira.writes.isEmpty && world.run(run.id)?.jiraCreated.isEmpty == true)
        _ = await world.call(run.id, "report_find", ["key": "leak", "title": "Token leak", "why": "Off brief."])
        #expect(jira.writes.count == 1)
        let ticket = try #require(world.run(run.id)?.finds.first?.ticket)
        #expect(world.run(run.id)?.jiraCreated["find/leak"] == ticket)
        #expect(await world.call(run.id, "jira_create", args).message == refusal)
        #expect(jira.writes.count == 1)
        #expect(world.run(run.id)?.finds.first?.ticket == ticket)
    }
}
