import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The broadcast row under the OPERATOR heading, as a value: it reads like a folded task row — the title
/// over its status line and `2 of 8 done`, its projects in the tooltip — and its `StatusMark` follows the
/// broadcast, a request outranking everything (spec §3, §13).
@Suite struct BroadcastRowTests {
    private let web = OperatorUIFixtures.project("pluto-web"), cms = OperatorUIFixtures.project("pluto-cms")
    private let docs = OperatorUIFixtures.project("pluto-docs")

    private func state(_ run: OperatorRun, _ tasks: [TaskItem] = []) -> AppState {
        var state = AppState()
        for project in [web, cms, docs] { state.append(project: project) }
        state.runs = [run]
        state.tasks = tasks
        return state
    }

    private func task(_ key: String, run: UUID, _ state: OperatedState, takenOver: Bool = false) -> TaskItem {
        OperatorUIFixtures.task(key, project: web.id,
                                operated: OperatorUIFixtures.operated(run: run, key: key, state: state,
                                                                      sha: [.accepted, .noChange, .published].contains(state) ? "4f2a91c00" : nil,
                                                                      takenOver: takenOver))
    }

    private func run(_ state: OperatorRunState = .active, firstPlanSize: Int? = 8,
                     questions: [OperatorQuestion] = []) -> OperatorRun {
        var run = OperatorUIFixtures.run(name: "Checkout redesign", state: state, questions: questions,
                                         projectIds: [web.id, cms.id, docs.id])
        run.firstPlanSize = firstPlanSize
        return run
    }

    @Test func theRowReadsLikeATaskRow() throws {
        let run = run()
        let tasks = [task("a", run: run.id, .accepted), task("b", run: run.id, .published)]
            + (0..<3).map { task("w\($0)", run: run.id, .working) } + (0..<3).map { task("q\($0)", run: run.id, .queued) }
            + [task("gone", run: run.id, .stopped)]
        let row = try #require(SidebarModel.broadcastRow(state: state(run, tasks)))
        #expect(row.id == run.id)
        #expect(row.title == "Checkout redesign")
        #expect(row.agent == .claude, "the Operator's agent is its avatar")
        #expect(row.progress == "2 of 8 done", "a stopped task is not counted")
        #expect(row.projectsHelp == "pluto-web, pluto-cms and pluto-docs")
        #expect(row.line == OperatorLine("monitoring 3 tasks", look: .acting), "its tasks work: the line moves")
    }

    @Test func thereIsNoProgressUntilTheFirstPlanIsInTodo() throws {
        let planning = run(.planning, firstPlanSize: nil)
        let row = try #require(SidebarModel.broadcastRow(state: state(planning)))
        #expect(row.progress == nil)
        #expect(row.line.text == "loading the construct")
        let planned = run(firstPlanSize: 7)
        let tasks = (0..<7).map { task("p\($0)", run: planned.id, .planned) }
        #expect(SidebarModel.broadcastRow(state: state(planned, tasks))?.progress == "0 of 7 done")
    }

    @Test func oneProjectIsNamedAloneAndNoBroadcastHasNoRow() throws {
        var single = run()
        single.projectIds = [cms.id]
        let row = try #require(SidebarModel.broadcastRow(state: state(single)))
        #expect(row.projectsHelp == "pluto-cms")
        #expect(SidebarModel.broadcastRow(state: AppState()) == nil)
        #expect(SidebarModel.broadcastRow(state: state(run(.stopped))) == nil, "an ended broadcast has no row")
        var ending = run()
        ending.intent = .stopped
        #expect(SidebarModel.broadcastRow(state: state(ending)) == nil, "nor one being ended")
    }

    @Test func theStatusMarkFollowsTheRequest() throws {
        // A request outranks everything: the words say it and the mark is amber, even while the
        // Operator acts on another task.
        let asking = run(questions: [OperatorUIFixtures.question("retry policy?")])
        let working = [task("a", run: asking.id, .working)]
        let acting = OperatorActs(runs: [asking.id: .init(act: .answering, task: "a")])
        let asked = try #require(SidebarModel.broadcastRow(state: state(asking, working), acting: acting))
        #expect(asked.line.look == .needsYou && asked.line.text == "waiting on you")
        #expect(asked.status == .needsInput)

        // Spinning while something works: its tasks, an act, or the plan being drawn up.
        let busy = run()
        #expect(SidebarModel.broadcastRow(state: state(busy, [task("a", run: busy.id, .working)]))?.status == .working)
        #expect(SidebarModel.broadcastRow(state: state(busy, [task("a", run: busy.id, .queued)]),
                                          acting: OperatorActs(runs: [busy.id: .init(act: .starting, task: "a")]))?.status == .working)
        #expect(SidebarModel.broadcastRow(state: state(run(.planning, firstPlanSize: nil)))?.status == .working)

        // The idle ring while paused, while its window is closed, or while it only waits on people.
        #expect(SidebarModel.broadcastRow(state: state(run(.paused), [task("a", run: busy.id, .working)]))?.status == .idle)
        #expect(SidebarModel.broadcastRow(state: state(run(.operatorOffline)))?.status == .idle)
        var reviewed = task("a", run: busy.id, .inReview)
        reviewed.operated?.peopleReview = PeopleReview(reviewers: ["Jan"])
        let waiting = try #require(SidebarModel.broadcastRow(state: state(busy, [task("b", run: busy.id, .accepted), reviewed])))
        #expect(waiting.line.text == "in review · waiting on Jan")
        #expect(waiting.status == .idle)

        // The accent dot once the debrief is ready.
        let done = try #require(SidebarModel.broadcastRow(state: state(run(.complete), [task("a", run: busy.id, .accepted)])))
        #expect(done.line.text == "done · debrief ready")
        #expect(done.status == .done)
    }

    /// A task's workers as iTerm2 lists them: its first worker in `first`, and an extra tab in `extra`.
    private func tabs(of task: TaskItem, first: SessionState, extra: SessionState? = nil) -> [SessionInfo] {
        func tab(_ id: String, _ state: SessionState, index: Int, key: String?) -> SessionInfo {
            SessionInfo(sessionId: id, windowId: "w-\(task.id)", tabIndex: index, taskId: task.id.uuidString, projectId: nil,
                        agent: .claude, model: nil, state: state, title: "", cwd: "/", tabKey: key)
        }
        return [tab("\(task.id)-1", first, index: 0, key: nil)] + (extra.map { [tab("\(task.id)-2", $0, index: 1, key: "tests")] } ?? [])
    }

    /// The row reads which tasks wait to be accepted from their workers' tabs: every worker ended its turn. With
    /// none at work its mark is the idle ring, as while it waits on people: the Operator checks the work next.
    @Test func aTaskWhoseWorkersAreDoneIsReadyToAccept() throws {
        let busy = run()
        let done = task("a", run: busy.id, .working), atWork = task("b", run: busy.id, .working)
        var tabbed = task("c", run: busy.id, .working)
        tabbed.operated?.extraTabs = [ExtraTab(key: "tests", agent: .claude, model: "m", reasoning: nil, modelReason: "Tests.",
                                               brief: "Write the tests.", launch: LaunchAttempt(number: 1, requestedAt: .distantPast,
                                                                                                openedAt: .distantPast), sessionId: "s")]
        let sessions = tabs(of: done, first: .idle) + tabs(of: atWork, first: .working) + tabs(of: tabbed, first: .done, extra: .working)
        let row = try #require(SidebarModel.broadcastRow(state: state(busy, [done, atWork, tabbed]), sessions: sessions))
        #expect(row.line == OperatorLine("monitoring 2 tasks · checking 1 next", look: .acting), "a tab still at work keeps its task working")
        #expect(row.status == .working)

        let waiting = try #require(SidebarModel.broadcastRow(state: state(busy, [done]), sessions: tabs(of: done, first: .done)))
        #expect(waiting.line == OperatorLine("checking 1 next"))
        #expect(waiting.status == .idle)
        // Without its tabs listed nothing says it is done: it is working, as before.
        #expect(SidebarModel.broadcastRow(state: state(busy, [done]))?.line == OperatorLine("monitoring 1 task", look: .acting))
        // The board's band says what the row says.
        let board = BroadcastBoard.make(run: busy, state: state(busy, [done]), acting: .none, requests: [], sessions: tabs(of: done, first: .idle))
        #expect(board.band == OperatorLine("checking 1 next"))
    }

    @Test func aPauseIsReadFromTheIntentToo() throws {
        var pausing = run()
        pausing.intent = .paused
        let row = try #require(SidebarModel.broadcastRow(state: state(pausing)))
        #expect(row.isPaused && row.status == .idle)
        #expect(try #require(SidebarModel.broadcastRow(state: state(run(.operatorOffline)))).isPaused)
        #expect(try !#require(SidebarModel.broadcastRow(state: state(run()))).isPaused)
    }
}
