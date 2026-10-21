import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The broadcast's group (decided 21 Oct 2026): its tasks move out of their projects, which count them; the
/// Operator's row speaks for its own session alone; a held task spins until it needs you; queued tasks sit last;
/// and what needs you is what Focus View, the Dock badge and the folded header's chip count.
@Suite struct BroadcastSectionTests {
    private let web = OperatorUIFixtures.project("pluto-web"), cms = OperatorUIFixtures.project("pluto-cms")

    private func state(_ run: OperatorRun?, _ tasks: [TaskItem] = []) -> AppState {
        var state = AppState()
        state.append(project: web); state.append(project: cms)
        state.runs = run.map { [$0] } ?? []
        state.tasks = tasks
        return state
    }

    private func run(_ state: OperatorRunState = .active, questions: [OperatorQuestion] = []) -> OperatorRun {
        var run = OperatorUIFixtures.run(name: "Checkout redesign", state: state, questions: questions, projectIds: [web.id, cms.id])
        run.firstPlanSize = 6
        return run
    }

    private func task(_ key: String, run: UUID, _ state: OperatedState, in project: Project? = nil, agent: AgentKind = .claude,
                      takenOver: Bool = false, id: UUID = UUID()) -> TaskItem {
        OperatorUIFixtures.task(key, id: id, agent: agent, project: (project ?? web).id,
                                operated: OperatorUIFixtures.operated(run: run, key: key, state: state,
                                                                      sha: [.accepted, .noChange, .published].contains(state) ? "4f2a91c00" : nil,
                                                                      takenOver: takenOver))
    }

    private func tab(_ task: TaskItem, _ state: SessionState) -> SessionInfo {
        SessionInfo(sessionId: "\(task.id)", windowId: "w-\(task.id)", tabIndex: 0, taskId: task.id.uuidString, projectId: nil,
                    agent: .claude, model: nil, state: state, title: "", cwd: task.worktreePath)
    }

    private func operatorTab(_ run: OperatorRun, _ state: SessionState) -> SessionInfo {
        SessionInfo(sessionId: "op", windowId: "operator-window", tabIndex: 0, taskId: run.id.uuidString, projectId: nil,
                    agent: .claude, model: nil, state: state, title: "", cwd: "/")
    }

    private func section(_ state: AppState, sessions: [SessionInfo] = [], acting: OperatorActs = .none) throws -> BroadcastSection {
        try #require(SidebarModel.broadcastSection(state: state, sessions: sessions, acting: acting))
    }

    private func sections(_ state: AppState, sessions: [SessionInfo] = []) -> [ProjectSection] {
        SidebarModel.sections(state: state, sessions: sessions, branchByCwd: [:], projectBranch: [:])
    }

    // -- out of their projects ---------------------------------------------------------

    @Test func theBroadcastsTasksMoveOutOfTheirProjectsWhichCountThem() throws {
        let run = run()
        var queued = task("queued", run: run.id, .queued, in: cms)
        queued.worktreePath = ""
        let mine = OperatorUIFixtures.task("Mine", project: web.id, operated: nil)
        let held = [task("a", run: run.id, .working), task("b", run: run.id, .accepted), queued]
        let drawn = sections(state(run, [mine] + held))
        #expect(drawn[0].tasks.map(\.title) == ["Mine"], "your own task stays")
        #expect(drawn[0].operatorTasks == 2 && drawn[0].operatorWorktrees == 2)
        #expect(drawn[1].tasks.isEmpty)
        #expect(drawn[1].operatorTasks == 1 && drawn[1].operatorWorktrees == 0, "a queued task has no worktree yet")
        #expect(drawn[1].isEmpty && drawn[1].collapsed, "a project left with only the Operator's tasks is empty")
        #expect(try section(state(run, [mine] + held)).tasks.map(\.title) == ["a", "b", "queued"])
    }

    @Test func anEndedBroadcastsTasksAreYoursAgain() throws {
        var ended = run()
        ended.state = .stopped
        let drawn = sections(state(ended, [task("a", run: ended.id, .working)]))
        #expect(drawn[0].tasks.map(\.title) == ["a"])
        #expect(drawn[0].operatorTasks == 0)
        #expect(SidebarModel.broadcastSection(state: state(ended), sessions: []) == nil, "and there is no group")
    }

    // -- the group ---------------------------------------------------------------------

    @Test func queuedTasksSitLastUnderTheirPlannedAgentsMark() throws {
        let run = run()
        let tasks = [task("first", run: run.id, .queued, agent: .codex), task("working", run: run.id, .working),
                     task("planned", run: run.id, .planned), task("merged", run: run.id, .published)]
        let group = try section(state(run, tasks))
        #expect(group.tasks.map(\.title) == ["working", "merged", "first", "planned"])
        #expect(group.tasks.map(\.queued) == [false, false, true, true])
        #expect(group.tasks[2].avatars == AvatarGroup(marks: [.codex], overflow: 0), "the planned agent, before any tab")
        #expect(group.tasks[2].status == .idle, "nothing runs yet: its mark is the pause sign, not the spinner")
        #expect(group.tasks[2].operatorLine?.text == "queued")
    }

    @Test func aHeldTaskSpinsUntilItNeedsYou() throws {
        let run = run()
        let working = task("working", run: run.id, .working), turnEnded = task("turn ended", run: run.id, .working)
        let asking = task("asking", run: run.id, .working), blocked = task("blocked", run: run.id, .blocked)
        let review = task("review", run: run.id, .inReview), merged = task("merged", run: run.id, .published)
        let mine = task("mine", run: run.id, .working, takenOver: true)
        let sessions = [tab(working, .idle), tab(turnEnded, .done), tab(asking, .needsInput), tab(merged, .done), tab(mine, .done)]
        let group = try section(state(run, [working, turnEnded, asking, blocked, review, merged, mine]), sessions: sessions)
        let status = Dictionary(uniqueKeysWithValues: group.tasks.map { ($0.title, $0.status) })
        #expect(status["working"] == .working, "an idle tab spins while the Operator holds it")
        #expect(status["turn ended"] == .working, "no done dot: the turn is the Operator's to read")
        #expect(status["asking"] == .needsInput, "a prompt is yours")
        #expect(status["blocked"] == .needsInput, "so is a block")
        #expect(status["review"] == .working)
        #expect(status["merged"] == .done, "ended: its own mark, which the row draws as the check")
        #expect(status["mine"] == .done, "taken over: yours, as any task of yours")
        #expect(SidebarModel.heldStatus(.idle, line: nil) == .idle)
        #expect(SidebarModel.heldStatus(.done, line: OperatorLine("left for you · 4f2a91c", look: .needsYou)) == .needsInput)
    }

    // -- the Operator's row ------------------------------------------------------------

    @Test func theOperatorsRowHasAnIdOfItsOwn() throws {
        let run = run()
        let row = try section(state(run)).operatorRow
        #expect(row.id != run.id && row.id == OperatorRow.id(of: run.id), "stable, and never the header's")
        #expect(row.runId == run.id && row.agent == .claude)
        #expect(OperatorRow.id(of: row.id) == run.id, "the derivation is its own inverse, so it can never meet the run's")
    }

    @Test func theOperatorsRowSpeaksForItsOwnSessionAlone() throws {
        let run = run(questions: [OperatorUIFixtures.question("which currency format?", task: nil)])
        let asked = try section(state(run)).operatorRow
        #expect(asked.line == OperatorLine("waiting on you", look: .needsYou, tooltip: "The Operator asks: which currency format?"))
        #expect(asked.status == .needsInput)

        // A task's prompt and a question about a task are that task's: the Operator's row goes on with its act.
        let busy = self.run()
        let drawer = task("Cart drawer", run: busy.id, .working)
        var asking = busy
        asking.questions = [OperatorUIFixtures.question("retry policy?", task: drawer.id)]
        let acting = OperatorActs(runs: [busy.id: .init(act: .answering, task: "Cart drawer")])
        let row = try section(state(asking, [drawer]), sessions: [tab(drawer, .needsInput)], acting: acting).operatorRow
        #expect(row.line == OperatorLine("answering Claude · Cart drawer", look: .acting))
        #expect(row.status == .working)

        // Its own tab waiting on input: it asks you in its window.
        let prompted = try section(state(busy, [drawer]), sessions: [operatorTab(busy, .needsInput)]).operatorRow
        #expect(prompted.line.look == .needsYou && prompted.status == .needsInput)

        // Between turns, an idle tab: the idle ring under what its tasks are doing.
        let review = task("review", run: busy.id, .inReview)
        let between = try section(state(busy, [review]), sessions: [operatorTab(busy, .idle)]).operatorRow
        #expect(between.status == .idle)
        #expect(between.line.look == .quiet)
    }

    @Test func theOperatorsRowSaysWhenItsPausedClosedOrDone() throws {
        var paused = run()
        paused.state = .paused
        #expect(try section(state(paused)).operatorRow.line.text == "paused")
        var closed = run()
        closed.state = .operatorOffline
        let offline = try section(state(closed)).operatorRow
        #expect(offline.line.text == "paused · the Operator’s window is closed" && offline.status == .idle)
        var complete = run()
        complete.state = .complete
        let done = try section(state(complete)).operatorRow
        #expect(done.line.text == "done · debrief ready" && done.status == .done)
    }

    // -- the header ------------------------------------------------------------------------

    @Test func theHeaderSaysItsProgressAndPausedBeforeIt() throws {
        let run = run()
        let tasks = [task("a", run: run.id, .published), task("b", run: run.id, .working)]
        let header = try section(state(run, tasks)).header
        #expect(header.progress == "1 of 2" && header.headerProgress == "1 of 2")
        var paused = run
        paused.intent = .paused
        #expect(try section(state(paused, tasks)).header.headerProgress == "paused · 1 of 2")
        var planning = run
        planning.firstPlanSize = nil
        planning.state = .paused
        #expect(try section(state(planning)).header.headerProgress == "paused", "no plan yet, no count")
    }

    // -- folded, and what needs you -----------------------------------------------------------

    @Test func theFoldIsTheWorkspacesAndWhatNeedsYouIsCountedOnce() throws {
        let run = run(questions: [OperatorUIFixtures.question("retry policy?", task: nil)])
        let asking = task("asking", run: run.id, .working), quiet = task("quiet", run: run.id, .working)
        var state = state(run, [quiet, asking])
        #expect(try !section(state).folded)
        state.setFolded(run: run.id, true)
        let group = try section(state, sessions: [tab(asking, .needsInput), tab(quiet, .done)])
        #expect(group.folded)
        #expect(group.needingAttention == [.operation(run.id), .task(asking.id)], "the Operator's row first, as drawn")
        #expect(group.attention == [StatusCount(status: .needsInput, count: 2)], "one amber chip, nothing else")
        #expect(group.firstNeedingAttention == .operation(run.id))
        state.setFolded(run: run.id, false)
        #expect(try !section(state).folded)
    }

    @Test func focusViewTheDockBadgeAndListViewKnowTheGroup() throws {
        let run = run()
        let asking = task("asking", run: run.id, .working), quiet = task("quiet", run: run.id, .working)
        let mine = OperatorUIFixtures.task("Mine", project: web.id, operated: nil)
        let state = state(run, [mine, quiet, asking])
        let sessions = [tab(asking, .needsInput), tab(quiet, .done), tab(mine, .done)]
        let group = try section(state, sessions: sessions), projects = sections(state, sessions: sessions)
        #expect(SidebarModel.needingAttention(projects, broadcast: group) == [.task(asking.id), .task(mine.id)])
        #expect(DockBadge.label(for: projects, broadcast: group) == "2", "a held task's turn ending is not counted")
        #expect(SidebarModel.needingAttention(projects, broadcast: group, skippingTasks: [asking.id]) == [.task(mine.id)])
        #expect(SidebarModel.focusView(projects, broadcast: group)[run.id] == false, "open: something in it needs you")
        #expect(SidebarModel.listView(projects, broadcast: group)[run.id] == false)

        let calm = try section(state, sessions: [tab(asking, .working)])
        #expect(SidebarModel.focusView(projects, broadcast: calm)[run.id] == true, "folded: nothing in it needs you")
    }

    @Test func theFoldIsSavedOnlyWhileSomethingIsFolded() throws {
        var state = AppState()
        let id = UUID()
        #expect(try !String(decoding: JSONEncoder().encode(state), as: UTF8.self).contains("foldedRuns"))
        state.setFolded(run: id, true)
        let decoded = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        #expect(decoded.foldedRuns == [id])
    }
}
