import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The Operator's Jira tools (spec §5, §L): jira_search and jira_board read, the writes need the broadcast's Jira slice, stay in
/// its Jira projects, are checked again right before they are sent, and a lost answer makes no second ticket.
@MainActor @Suite struct OperatorJiraToolsTests {
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

    @Test func jiraSearchIsKeptToTheBroadcastsLinkedJiraProjects() async throws {
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

    // -- Jira writes (spec §5): the first slice -----------------------------------------------------

    /// A run whose frozen Jira slice is `slice`, in the Jira projects PLUTO and WEB.
    func jiraRun(slice: Bool) -> OperatorRun {
        var run = OperatorServiceFixtures.run(projects: [project])
        run.profile.slices.jira = slice
        run.jiraProjectKeys = ["PLUTO", "WEB"]
        return run
    }

    /// A `jira_create` call for PLUTO, with `changes` over its arguments.
    func ticket(_ changes: [String: JSONValue] = [:]) -> JSONValue { Self.ticketArguments(changes) }
    nonisolated static func ticketArguments(_ changes: [String: JSONValue] = [:]) -> JSONValue {
        .object(["key": "t1", "project": "PLUTO", "type": "Task", "summary": "Handle SIGTERM", "description": "Drain the tasks."]
            .merging(changes) { _, new in new })
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

    @Test func jiraSearchNeedsAJiraProjectLinkedToTheBroadcast() async throws {
        let unlinked = OperatorServiceFixtures.project(name: "Plain")
        let run = OperatorServiceFixtures.run(projects: [unlinked])
        let jira = FakeJira(tickets: [])
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [unlinked], runs: [run])) { $0.jira = { jira } }
        let answer = await world.call(run.id, "jira_search", ["jql": "x"])
        #expect(answer.message == "None of this broadcast’s projects is linked to a Jira project, so there is nothing jira_search may search.")
        #expect(jira.searches.isEmpty)
    }

    // MARK: - Gate C: Jira writes wait while the broadcast does not run, and a lost answer makes no second ticket

    /// The label `jira_create` gives the ticket for `key` in `run`.
    static func label(_ run: OperatorRun, _ key: String) -> String {
        // All these fixtures use t1; this is its independently calculated SHA-256 digest.
        precondition(key == "t1")
        return "aiterm-v2-\(run.id.uuidString.lowercased())-628b49d96dcde97a430dd4f597705899e09a968f793491e4b704cae33a40dc02"
    }

    @Test(arguments: [(OperatorRunState.active, OperatorRunState?.some(.paused)), (.paused, .paused), (.operatorOffline, nil),
                      (.planning, .paused)])
    func jiraWritesWaitWhileTheBroadcastDoesNotRun(_ state: OperatorRunState, _ intent: OperatorRunState?) async throws {
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
    // -- what every Jira tool says the same way -----------------------------------------------------

    /// A call of each Jira tool, valid in PLUTO and WEB.
    nonisolated static let jiraCalls: [(tool: String, arguments: JSONValue)] = [
        ("jira_search", ["jql": "x"]), ("jira_board", [:]), ("jira_create", ticketArguments()),
        ("jira_move", ["key": "PLUTO-231", "status": "Done"]), ("jira_link", ["key": "PLUTO-1", "to": "WEB-2", "type": "Blocks"]),
        ("jira_sprint", ["key": "s1", "tickets": ["PLUTO-1"], "sprint": 41]), ("jira_edit", ["key": "e1", "ticket": "PLUTO-1", "summary": "s"]),
        ("jira_comment", ["key": "c1", "ticket": "PLUTO-1", "body": "Hi."]),
    ]

    /// With no Jira connected, every Jira tool says where to connect it.
    @Test(arguments: jiraCalls)
    func aJiraToolWithoutJiraSaysWhere(_ tool: String, _ arguments: JSONValue) async throws {
        let run = jiraRun(slice: true)
        let world = try makeWorld(run)
        #expect(await world.call(run.id, tool, arguments).message == "Jira isn’t connected in AiTerm’s Settings › Integrations.")
    }

    /// Each write with the slice off: refused, nothing written, and what was not done left for the person, once.
    @Test(arguments: [
        ("jira_create", ticketArguments(), "Create the Jira ticket “Handle SIGTERM” in PLUTO: the Jira slice is off."),
        ("jira_move", ["key": "PLUTO-231", "status": "Done"], "Move PLUTO-231 to Done: the Jira slice is off."),
        ("jira_link", ["key": "PLUTO-1", "to": "WEB-2", "type": "Blocks"], "Link PLUTO-1 to WEB-2 (Blocks): the Jira slice is off."),
        ("jira_sprint", ["key": "s1", "tickets": ["PLUTO-1", "WEB-2"], "sprint": 41], "Put PLUTO-1, WEB-2 in sprint 41: the Jira slice is off."),
        ("jira_sprint", ["key": "s2", "tickets": ["PLUTO-1"], "sprint": "backlog"], "Move PLUTO-1 to the backlog: the Jira slice is off."),
        ("jira_edit", ["key": "e1", "ticket": "PLUTO-1", "summary": "A better title"], "Edit PLUTO-1: the Jira slice is off."),
        ("jira_comment", ["key": "c1", "ticket": "PLUTO-1", "body": "Done."], "Comment on PLUTO-1: the Jira slice is off."),
    ] as [(String, JSONValue, String)])
    func aJiraWriteNeedsTheSlice(_ tool: String, _ arguments: JSONValue, _ left: String) async throws {
        let jira = agileJira()
        let run = jiraRun(slice: false)
        let world = try makeWorld(run, jira: jira)
        #expect(await world.call(run.id, tool, arguments).message == "The Jira slice is off for this broadcast.")
        #expect(jira.writes.isEmpty && world.run(run.id)?.jiraCommented.isEmpty == true)
        #expect(world.run(run.id)?.leftForYou == [left])
        _ = await world.call(run.id, tool, arguments)
        #expect(world.run(run.id)?.leftForYou == [left], "the same sentence is kept once")
    }

    /// A Jira write naming a project or ticket outside the broadcast's is refused, slice on or off, and is nobody's to do.
    @Test(arguments: [
        ("jira_move", ["key": "PAY-9", "status": "Done"], "PAY-9 isn’t in this broadcast’s Jira projects: PLUTO, WEB."),
        ("jira_create", ticketArguments(["project": "PAY"]), "PAY isn’t in this broadcast’s Jira projects: PLUTO, WEB."),
        ("jira_create", ticketArguments(["parent": "PAY-1"]), "PAY-1 isn’t in this broadcast’s Jira projects: PLUTO, WEB."),
        ("jira_link", ["key": "PLUTO-1", "to": "PAY-2", "type": "Blocks"], "PAY-2 isn’t in this broadcast’s Jira projects: PLUTO, WEB."),
        ("jira_link", ["key": "PAY-2", "to": "PLUTO-1", "type": "Blocks"], "PAY-2 isn’t in this broadcast’s Jira projects: PLUTO, WEB."),
        ("jira_move", ["key": "PLUTO", "status": "Done"], "PLUTO isn’t a Jira ticket key like PLUTO-231."),
        ("jira_sprint", ["key": "s1", "tickets": ["PLUTO-1", "PAY-9"], "sprint": 41], "PAY-9 isn’t in this broadcast’s Jira projects: PLUTO, WEB."),
        ("jira_sprint", ["key": "s2", "tickets": ["PAY-9"], "sprint": "backlog"], "PAY-9 isn’t in this broadcast’s Jira projects: PLUTO, WEB."),
        ("jira_edit", ["key": "e1", "ticket": "PAY-9", "summary": "A better title"], "PAY-9 isn’t in this broadcast’s Jira projects: PLUTO, WEB."),
        ("jira_edit", ["key": "e1", "ticket": "not a key", "summary": "A better title"], "not a key isn’t a Jira ticket key like PLUTO-231."),
        ("jira_comment", ["key": "c1", "ticket": "PAY-9", "body": "Hi."], "PAY-9 isn’t in this broadcast’s Jira projects: PLUTO, WEB."),
    ] as [(String, JSONValue, String)])
    func aJiraWriteStaysInScope(_ tool: String, _ arguments: JSONValue, _ refusal: String) async throws {
        let jira = agileJira()
        for slice in [true, false] {
            let run = jiraRun(slice: slice)
            let world = try makeWorld(run, jira: jira)
            #expect(await world.call(run.id, tool, arguments).message == refusal, "slice \(slice)")
            #expect(world.run(run.id)?.leftForYou.isEmpty == true, "a write outside the scope is nobody's to do for this broadcast")
        }
        #expect(jira.writes.isEmpty)
    }

    @Test func jiraSprintNeedsTicketsAndASprint() async throws {
        let jira = agileJira()
        let run = jiraRun(slice: true)
        let world = try makeWorld(run, jira: jira)
        #expect(await world.call(run.id, "jira_sprint", ["key": "s3", "tickets": [], "sprint": 41]).message == "jira_sprint needs `tickets`, the keys to move.")
        #expect(await world.call(run.id, "jira_sprint", ["key": "s4", "tickets": ["PLUTO-1"]]).message == "jira_sprint needs `sprint`.")
        #expect(jira.writes.isEmpty)
    }

    @Test func aJiraFailureSaysWhy() async throws {
        let run = jiraRun(slice: true)
        let jira = FakeJira()
        jira.failWrites()
        let world = try makeWorld(run, jira: jira)
        #expect(await world.call(run.id, "jira_move", ["key": "PLUTO-1", "status": "Done"]).message == "Jira returned an error (HTTP 500). Try again.")
    }

}
