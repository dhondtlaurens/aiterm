import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// A task's worker tabs: its first worker, then each extra tab the Operator added (`open_tab`), each with the tab
/// iTerm2 lists for it.
@Suite struct WorkerTabsTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func session(_ id: String, task: UUID, index: Int = 0, agent: SessionAgent = .claude, state: SessionState = .working,
                 key: String? = nil) -> SessionInfo {
        var session = SessionInfo(sessionId: id, windowId: "w1", tabIndex: index, taskId: task.uuidString, projectId: nil,
                                  agent: agent, model: nil, state: state, title: "", cwd: "/tmp")
        session.tabKey = key
        return session
    }

    func extra(_ key: String, sessionId: String? = nil, opened: Bool = false, failure: String? = nil) -> ExtraTab {
        ExtraTab(key: key, agent: .codex, model: "gpt-6-mini", reasoning: nil, modelReason: "Tests.", brief: "Write the tests.",
                 launch: LaunchAttempt(number: 1, requestedAt: start, openedAt: opened ? start : nil), sessionId: sessionId, failure: failure)
    }

    func task(_ tabs: [ExtraTab]) -> TaskItem {
        var world = OperatedWorld()
        let id = world.addTask("T-1", run: world.addRun(), state: .working)
        world.update(id) { $0.extraTabs = tabs }
        return world.state.task(id: id)!
    }

    /// What its workers left running in the background holds a task that ended its turn: it is not ready, its line
    /// says `Operator watching · in background`, and only an ended turn's background counts.
    @Test func backgroundWorkHoldsATaskThatEndedItsTurn() throws {
        var world = OperatedWorld()
        let id = world.addTask("T-1", run: world.addRun(), state: .working)
        let task = try #require(world.state.task(id: id))
        let runId = try #require(task.operated?.runId)
        let run = try #require(world.state.run(id: runId))
        var done = session("s1", task: task.id, state: .done)
        done.background = ["npm run test:run"]
        #expect(task.workerTabs(in: [done]).flatMap(\.background) == ["npm run test:run"])
        #expect(!task.isReadyForAcceptance(in: [done]))
        let line = try #require(OperatorLine.task(task, run: run, acting: nil, requests: [], sessions: [done]))
        #expect(line.text == "Operator watching · in background" && line.look == .acting)
        #expect(line.tooltip == "Running in the background: npm run test:run")
        done.background = []
        #expect(task.isReadyForAcceptance(in: [done]))
        var working = session("s1", task: task.id, state: .working)
        working.background = ["npm run dev"]
        #expect(task.workerTabs(in: [working]).flatMap(\.background).isEmpty, "a turn under way waits on nothing yet")
    }

    @Test func aTaskWithNoExtraTabHasItsFirstWorkerAlone() {
        let task = task([])
        let tabs = task.workerTabs(in: [session("s1", task: task.id)])
        #expect(tabs.count == 1)
        #expect(tabs[0].key == nil && tabs[0].agent == .claude && tabs[0].model == task.model && tabs[0].session?.sessionId == "s1")
        #expect(tabs[0].status == .working && !tabs[0].isOpening)
        #expect(task.workerTabs(in: []).map(\.status) == [nil], "no tab listed: no status")
    }

    /// An extra tab moved before the first worker in its window is still not the first worker.
    @Test func theFirstWorkerIsNeverAnExtraTab() {
        let task = task([extra("review", sessionId: "s2", opened: true)])
        let sessions = [session("s2", task: task.id, index: 0, agent: .codex, state: .idle, key: "review"),
                        session("s1", task: task.id, index: 1)]
        #expect(task.firstWorker(in: sessions)?.sessionId == "s1")
        let tabs = task.workerTabs(in: sessions)
        #expect(tabs.map(\.key) == [nil, "review"])
        #expect(tabs.map { $0.session?.sessionId } == ["s1", "s2"] && tabs.map(\.status) == [.working, .idle])
        #expect(tabs[1].agent == .codex && tabs[1].model == "gpt-6-mini")
    }

    /// Asked for and not shown yet, or listed as the shell its command is typed into: still opening, which counts as at
    /// work. Closed once it showed: listed with no status. Refused: no tab at all.
    @Test func anExtraTabStillOpeningCountsAsAtWorkAndAClosedOneHasNoStatus() {
        let task = task([extra("waiting"), extra("typing", sessionId: "s3", opened: true), extra("closed", sessionId: "s4", opened: true),
                         extra("refused", failure: "No window.")])
        let tabs = task.workerTabs(in: [session("s1", task: task.id, state: .idle),
                                        session("s3", task: task.id, index: 2, agent: .shell, state: .idle, key: "typing")])
        #expect(tabs.map(\.key) == [nil, "waiting", "typing", "closed"])
        #expect(tabs.map(\.isOpening) == [false, true, true, false])
        #expect(tabs.map(\.status) == [.idle, .working, .working, nil])
        #expect(tabs.map(\.isClosed) == [false, false, false, true])
        #expect(!task.workerTabs(in: [])[0].isClosed, "a first worker with no tab listed is never closed")
    }

    /// The first worker's conversation, as its window last showed it: the first of its agent's that no extra tab named,
    /// wherever that tab stood in the window.
    @Test func theFirstWorkersConversationIsNoExtraTabs() {
        var task = task([{ var tab = extra("review"); tab.agent = .claude; tab.conversation = "conv-review"; return tab }()])
        task.conversations = [TaskConversation(agent: .claude, id: "conv-review"), TaskConversation(agent: .codex, id: "conv-codex"),
                              TaskConversation(agent: .claude, id: "conv-main")]
        #expect(task.firstWorkerConversation?.id == "conv-main")
        task.conversations = [TaskConversation(agent: .claude, id: "conv-review")]
        #expect(task.firstWorkerConversation == nil)
    }

    // MARK: - Which tab a click brings forward (P5 A, 21 Oct 2026)

    /// A row's click brings the tab that asks; of several, the first by `OperatorLine.first`'s order, then by tab
    /// order (`main`, then the extra tabs as they opened); with none asking, the tab last in front in its window.
    @Test func aClickBringsTheAskingTabElseTheOneLastInFront() {
        let task = task([extra("docs", sessionId: "s2", opened: true), extra("e2e-tests", sessionId: "s3", opened: true)])
        func tabs(main: SessionState = .working, docs: SessionState = .working, e2e: SessionState = .working,
                  active: String = "s1") -> [SessionInfo] {
            var listed = [session("s1", task: task.id, state: main), session("s2", task: task.id, index: 1, state: docs, key: "docs"),
                          session("s3", task: task.id, index: 2, state: e2e, key: "e2e-tests")]
            for i in listed.indices { listed[i].active = listed[i].sessionId == active }
            return listed
        }
        func prompt(_ tab: String, _ kind: BroadcastRequest.Kind = .permission) -> BroadcastRequest {
            BroadcastRequest(kind: kind, runId: task.operated!.runId, taskId: task.id, text: "Asks.", tab: tab)
        }
        // Nothing asks: the tab last in front, as its window last showed it.
        #expect(task.tabToBring(sessions: tabs(active: "s3"), requests: [])?.sessionId == "s3")
        #expect(task.tabToBring(sessions: tabs(active: "none"), requests: [])?.sessionId == "s1", "none in front: its first worker")
        // One asks: that one, whichever is in front.
        #expect(task.tabToBring(sessions: tabs(active: "s1"), requests: [prompt("docs")])?.sessionId == "s2")
        #expect(task.tabToBring(sessions: tabs(e2e: .needsInput), requests: [])?.sessionId == "s3", "a prompt not recorded yet asks too")
        // Several ask: by tab order between equals, `main` first.
        #expect(task.tabToBring(sessions: tabs(docs: .needsInput, e2e: .needsInput, active: "s1"), requests: [])?.sessionId == "s2")
        #expect(task.tabToBring(sessions: tabs(main: .needsInput, e2e: .needsInput), requests: [prompt("e2e-tests")])?.sessionId == "s1")
        // A request no one tab makes, or another task's, picks none.
        let question = BroadcastRequest(kind: .question, runId: task.operated!.runId, taskId: task.id, text: "The Operator asks.")
        var elsewhere = prompt("docs")
        elsewhere.taskId = UUID()
        #expect(task.tabToBring(sessions: tabs(active: "s3"), requests: [question, elsewhere])?.sessionId == "s3")
        // A tab of the task that is no worker's (a review opened in its window) in front is the one last in front.
        var review = session("s4", task: task.id, index: 3, agent: .codex, state: .idle, key: nil)
        review.active = true
        #expect(task.tabToBring(sessions: tabs(active: "none") + [review], requests: [])?.sessionId == "s4")
        // None listed: nothing to bring, its window comes back as a row's click brings it today.
        #expect(task.tabToBring(sessions: [], requests: [prompt("docs")]) == nil)
    }
}
