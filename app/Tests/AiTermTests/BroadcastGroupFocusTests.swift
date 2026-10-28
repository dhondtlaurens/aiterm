import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The broadcast's group, chosen (decided 21 Oct 2026): the header folds on a click or ↩ and opens the board
/// from its button and its menu; the Operator's row peeks at the Operator's window on ↑ ↓ and brings it to
/// front on a click or ↩, reopening it in front when it is closed; a queued task's row is selectable and opens
/// nothing. The two rows never share an id.
@MainActor
struct BroadcastGroupFocusTests {
    private func controller(_ run: OperatorRun, failing: [String: DaemonError.Code] = [:],
                            activateIterm: @escaping @MainActor () -> Void = {}) throws -> (AppController, RecordingDaemon) {
        let controller = AppController(preferences: .scratch(), activateIterm: activateIterm)
        try controller.loadWorkspace()
        controller.workspace.mutate { $0.runs = [run] }
        let daemon = RecordingDaemon(failing: failing)
        controller.helper.setDaemonClient(daemon)
        return (controller, daemon)
    }

    private func activated(_ daemon: RecordingDaemon) -> [String?] {
        daemon.requests("window.activate").map { $0.params["windowId"] as? String }
    }

    /// The Operator's tab as iTerm2 lists it: tagged with the broadcast, in its window.
    static func operatorTab(of run: OperatorRun, _ state: SessionState = .working) -> SessionInfo {
        SessionInfo(sessionId: "op", windowId: run.operatorWindowId ?? "operator-window", tabIndex: 0, taskId: run.id.uuidString,
                    projectId: nil, agent: .claude, model: nil, state: state, title: "", cwd: "/")
    }

    /// The OPERATOR heading carries the broadcast (28 Oct 2026): the Operator's row, its lead, is its one row, with an
    /// id of its own, never the run's.
    @Test func theOperatorsRowIsTheBroadcastsOneRow() throws {
        let run = OperatorUIFixtures.run(windowId: "operator-window")
        let (controller, _) = try controller(run)
        defer { controller.shutdown() }
        let operatorRow = OperatorRow.id(of: run.id)
        #expect(controller.focus.row(id: run.id) == nil, "no header row")
        #expect(controller.focus.row(id: operatorRow) == .operation(run.id))
        #expect(RowSelection.operation(run.id).id == operatorRow)
        controller.focus.browse(.operation(run.id))
        #expect(controller.focus.isSelected(operatorRow) && !controller.focus.isSelected(run.id))
    }

    /// Part G: one click leaves the Operator's window in front, iTerm2 with it. ↑ ↓ only peek at it.
    @Test func theOperatorsRowPeeksAndAClickBringsItsWindowToFront() async throws {
        let run = OperatorUIFixtures.run(windowId: "operator-window")
        var itermActivated = 0
        let (controller, daemon) = try controller(run, activateIterm: { itermActivated += 1 })
        defer { controller.shutdown() }
        controller.live.sessions = [Self.operatorTab(of: run)]
        controller.focus.onChoosingOperationWithoutWindow { _ in Issue.record("its window is open"); return nil }

        // ↓ onto the row: the window comes forward beside the sidebar; iTerm2 stays behind.
        await controller.focus.peek(id: OperatorRow.id(of: run.id))?.value
        #expect(activated(daemon) == ["operator-window"])
        #expect(itermActivated == 0, "a peek only looks")

        // A click: the window in front, and iTerm2 with it. No board.
        await controller.focus.select(.operation(run.id))?.value
        #expect(activated(daemon) == ["operator-window", "operator-window"])
        #expect(itermActivated == 1)
        #expect(controller.sheet == nil, "the board is the header's button's")

        // ↩ does what the click does.
        await controller.activateSelection()?.value
        #expect(activated(daemon).count == 3)
        #expect(itermActivated == 2)
        #expect(controller.focus.selection == .operation(run.id))
    }

    /// Closed, the click reopens the window in front: asked of the operator controller, never behind a board.
    @Test func aClosedOperatorWindowReopensInFront() async throws {
        let run = OperatorUIFixtures.run(windowId: nil)
        let (controller, daemon) = try controller(run)
        defer { controller.shutdown() }
        var asked: [UUID] = []
        controller.focus.onChoosingOperationWithoutWindow { id in asked.append(id); return nil }
        controller.focus.select(.operation(run.id))
        controller.activateSelection()
        #expect(asked == [run.id, run.id])
        #expect(controller.focus.selection == .operation(run.id))
        #expect(daemon.requests("window.activate").isEmpty)
        #expect(controller.sheet == nil)
    }

    /// A window closed before the app heard — its id still recorded, iTerm2 answering "not found" —
    /// comes back on the click too, as a missing one does. A peek never reopens anything.
    @Test func aWindowThatTurnsOutGoneIsAskedBackToo() async throws {
        let run = OperatorUIFixtures.run(windowId: "operator-window")
        let (controller, daemon) = try controller(run, failing: ["window.activate": .notFound])
        defer { controller.shutdown() }
        var asked: [UUID] = []
        controller.focus.onChoosingOperationWithoutWindow { id in asked.append(id); return nil }
        await controller.focus.peek(.operation(run.id))?.value
        #expect(asked.isEmpty, "a peek only looks")
        await controller.focus.select(.operation(run.id))?.value
        #expect(asked == [run.id])
        #expect(daemon.requests("window.activate").count == 2)
        #expect(controller.focus.selection == .operation(run.id))
    }

    /// A click on either heading switches the open section: OPERATOR folded opens the projects, and back; its board
    /// button and Open Board open the board, and move nothing else.
    @Test func theHeadingsFoldIntoEachOtherAndTheBoardButtonOpensTheBoard() async throws {
        let run = OperatorUIFixtures.run(windowId: "operator-window")
        let (controller, daemon) = try controller(run)
        defer { controller.shutdown() }
        #expect(controller.rows.broadcast?.folded == false && controller.rows.projectsFolded, "a broadcast opens the Operator")
        controller.toggleFolded(run: run.id)
        #expect(controller.state.foldedRuns == [run.id])
        #expect(controller.rows.broadcast?.folded == true && !controller.rows.projectsFolded)
        controller.toggleFolded(run: run.id)
        #expect(controller.state.foldedRuns.isEmpty && controller.rows.projectsFolded)
        #expect(controller.sheet == nil)

        controller.openBoard(run.id)
        guard case .broadcastBoard(let id)? = controller.sheet else { Issue.record("no board"); return }
        #expect(id == run.id)
        controller.sheets.sheet = nil
        controller.perform(.openBoard, onBroadcast: run.id)
        guard case .broadcastBoard? = controller.sheet else { Issue.record("no board from its menu"); return }
        #expect(controller.focus.selection == nil)
        #expect(daemon.requests("window.activate").isEmpty)
    }

    /// The fold is the workspace's, saved with it as a project's is, and Focus View and List View set it.
    @Test func theFoldIsSavedAndTheViewsSetIt() async throws {
        let run = OperatorUIFixtures.run(questions: [OperatorUIFixtures.question("retry policy?")])
        let (controller, daemon) = try controller(run)
        defer { controller.shutdown() }
        controller.toggleFolded(run: run.id)
        #expect(try controller.savedWorkspace().foldedRuns == [run.id])

        // ⌘L opens it; ⌘F keeps it open while the Operator asks, and peeks at the Operator's window.
        controller.showListView()
        #expect(controller.state.foldedRuns.isEmpty)
        controller.toggleFolded(run: run.id)
        await controller.showFocusView()?.value
        #expect(controller.state.foldedRuns.isEmpty, "something in it needs you")
        #expect(controller.focus.selection == .operation(run.id))
        #expect(activated(daemon) == ["operator-window"])

        // Nothing asked: Focus View folds it.
        controller.workspace.mutate { $0.runs[0].questions = [] }
        controller.showFocusView()
        #expect(controller.state.foldedRuns == [run.id])
    }

    /// The folded OPERATOR heading's amber chip opens its section at its first row that needs you.
    @Test func theAmberChipOpensTheGroupAtWhatNeedsYou() async throws {
        let run = OperatorUIFixtures.run()
        let project = OperatorUIFixtures.project("pluto-web")
        let quiet = OperatorUIFixtures.task("Quiet", project: project.id, windowId: "w1",
                                            operated: OperatorUIFixtures.operated(run: run.id, key: "a", state: .working))
        let blocked = OperatorUIFixtures.task("Blocked", project: project.id, windowId: "w2",
                                              operated: OperatorUIFixtures.operated(run: run.id, key: "b", state: .blocked,
                                                                                    blockedReason: "the tests fail on main"))
        let (controller, daemon) = try controller(run)
        defer { controller.shutdown() }
        controller.workspace.mutate { state in state.append(project: project); state.tasks = [quiet, blocked]; state.setFolded(run: run.id, true) }
        #expect(controller.rows.broadcast?.attention == [StatusCount(status: .needsInput, count: 1)])
        await controller.openAttention(of: run.id)?.value
        #expect(controller.rows.broadcast?.folded == false)
        #expect(controller.focus.selection == .task(blocked.id))
        #expect(activated(daemon) == ["w2"], "its window shown, as the arrows show one")
    }

    /// A row selected in the folded section from away from the list (a notification, Focus View) opens it, folding
    /// the other: a project's task folds the Operator's section, the broadcast's opens it again.
    @Test func aRowSelectedInTheFoldedSectionOpensIt() async throws {
        let run = OperatorUIFixtures.run()
        let web = OperatorUIFixtures.project("pluto-web"), cms = OperatorUIFixtures.project("pluto-cms")
        let elsewhere = OperatorUIFixtures.task("Elsewhere", project: web.id, windowId: "w1",
                                                operated: OperatorUIFixtures.operated(run: run.id, key: "a", state: .working))
        let here = OperatorUIFixtures.task("Here", project: cms.id, windowId: "w2",
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "b", state: .working))
        let mine = OperatorUIFixtures.task("Mine", project: cms.id, windowId: "w3", operated: nil)
        let (controller, _) = try controller(run)
        defer { controller.shutdown() }
        controller.workspace.mutate { state in
            state.append(project: web); state.append(project: cms); state.tasks = [elsewhere, here, mine]
        }
        #expect(controller.rows.projectsFolded)
        controller.reveal(.operation(run.id))
        controller.reveal(.task(here.id))
        #expect(controller.rows.projectsFolded, "the Operator's own rows are open already")
        controller.reveal(.task(mine.id))
        #expect(controller.rows.broadcast?.folded == true && !controller.rows.projectsFolded)
        controller.reveal(.project(web.id))
        #expect(controller.rows.broadcast?.folded == true, "the projects are open already")
        controller.reveal(.task(elsewhere.id))
        #expect(controller.rows.broadcast?.folded == false && controller.rows.projectsFolded)
    }

    /// 2B: a queued task's row is selected by a click, ↩ or the arrows, and nothing opens: no window, no board,
    /// and never the error a task without a window raises.
    @Test func aQueuedTaskIsSelectedAndOpensNothing() async throws {
        let run = OperatorUIFixtures.run()
        let project = OperatorUIFixtures.project("pluto-web")
        let queued = OperatorUIFixtures.task("Queued", project: project.id, windowId: nil,
                                             operated: OperatorUIFixtures.operated(run: run.id, key: "q", state: .queued))
        let (controller, daemon) = try controller(run)
        defer { controller.shutdown() }
        controller.workspace.mutate { state in state.append(project: project); state.tasks = [queued] }
        controller.focus.onChoosingOperatedTaskWithoutWindow { _ in Issue.record("nothing reopens"); return nil }
        controller.focus.onChoosingOwedRow { _ in Issue.record("nothing restores"); return nil }
        #expect(controller.rows.broadcast?.tasks.map(\.queued) == [true])
        #expect(controller.choose(task: queued.id) == nil, "a click")
        #expect(controller.focus.select(.task(queued.id)) == nil)
        #expect(controller.focus.selection == .task(queued.id))
        #expect(controller.activateSelection() == nil)
        await controller.focus.peek(id: queued.id)?.value
        #expect(controller.sheet == nil)
        #expect(controller.issue == nil, "no “hasn’t started” error")
        #expect(daemon.requests("window.activate").isEmpty)
        #expect(daemon.requests("session.activate").isEmpty)
    }

    /// P5 A: a driven task's row, clicked or ↩, raises its window and brings forward the worker tab that asks,
    /// whichever tab the window showed last (`TaskItem.tabToBring`, `session.activate`).
    @Test func aDrivenRowBringsTheTabThatAsks() async throws {
        let run = OperatorUIFixtures.run()
        let project = OperatorUIFixtures.project("pluto-web")
        var operated = OperatorUIFixtures.operated(run: run.id, key: "a", state: .working)
        operated.extraTabs = [OperatorUIFixtures.extraTab("docs"), OperatorUIFixtures.extraTab("e2e-tests")]
        var task = OperatorUIFixtures.task("Cart drawer", project: project.id, windowId: nil, operated: operated)
        task.windowId = "w-\(task.id)"
        let (controller, daemon) = try controller(run)
        defer { controller.shutdown() }
        controller.workspace.mutate { state in state.append(project: project); state.tasks = [task] }
        controller.live.sessions = [OperatorUIFixtures.tab("s1", of: task, .working, active: true),
                                    OperatorUIFixtures.tab("s2", of: task, .needsInput, index: 1, key: "docs", agent: .codex),
                                    OperatorUIFixtures.tab("s3", of: task, .idle, index: 2, key: "e2e-tests", agent: .codex)]
        #expect(controller.rows.broadcast?.tasks.first?.status == .needsInput, "its docs tab waits on input")

        await controller.choose(task: task.id)?.value                      // a click
        #expect(controller.focus.selection == .task(task.id))
        #expect(activated(daemon) == [task.windowId])
        #expect(daemon.requests("session.activate").map { $0.params["sessionId"] as? String } == ["s2"], "the tab that asks")

        await controller.activateSelection()?.value                        // ↩
        #expect(daemon.requests("session.activate").map { $0.params["sessionId"] as? String } == ["s2", "s2"])

        controller.openNote(.task(task.id))                                // its notification's click
        #expect(await eventually(describing: "the notification brings the tab that asks") {
            daemon.requests("session.activate").map { $0.params["sessionId"] as? String } == ["s2", "s2", "s2"]
        })

        // Answered, nothing asks: the tab last in front.
        controller.live.sessions[1].state = .working
        await controller.choose(task: task.id)?.value
        #expect(daemon.requests("session.activate").last?.params["sessionId"] as? String == "s1")
    }

    /// An ask_you about a task is answered in the Operator's window. Choosing its waiting row
    /// reaches that question until it is resolved, then returns to the task's worker.
    @Test func aTaskWaitingForAnOperatorQuestionOpensTheQuestion() async throws {
        let run = OperatorUIFixtures.run(windowId: "operator-window")
        let project = OperatorUIFixtures.project("pluto-web")
        let operated = OperatorUIFixtures.operated(run: run.id, key: "P2", state: .working, flags: [.waitingOnYou])
        let task = OperatorUIFixtures.task("Pick an effort", project: project.id, windowId: "worker-window", operated: operated)
        let (controller, daemon) = try controller(run)
        defer { controller.shutdown() }
        controller.workspace.mutate { state in
            state.append(project: project)
            state.tasks = [task]
            state.runs[0].questions = [OperatorUIFixtures.question("Which effort?", task: task.id)]
        }
        controller.live.sessions = [Self.operatorTab(of: run), OperatorUIFixtures.tab("s1", of: task, .idle)]
        #expect(controller.rows.broadcast?.tasks.first?.operatorLine?.look == .needsYou)
        #expect(controller.rows.broadcast?.operatorRow.status == .needsInput)
        await controller.choose(task: task.id)?.value
        #expect(controller.focus.selection == .operation(run.id))
        #expect(activated(daemon) == ["operator-window"])
        #expect(daemon.requests("session.activate").isEmpty)

        controller.live.sessions[1].state = .needsInput
        await controller.choose(task: task.id)?.value
        #expect(controller.focus.selection == .task(task.id), "a live worker prompt still takes priority")
        #expect(daemon.requests("session.activate").last?.params["sessionId"] as? String == "s1")
        controller.live.sessions[1].state = .idle

        controller.workspace.mutate { $0.runs[0].questions[0].resolution = "Use medium." }
        await controller.choose(task: task.id)?.value
        #expect(controller.focus.selection == .task(task.id), "a resolved question no longer redirects the task")
    }

    /// A task of your own is raised as ever: its window, no tab of it chosen.
    @Test func aTaskOfYourOwnBringsOnlyItsWindow() async throws {
        let run = OperatorUIFixtures.run()
        let project = OperatorUIFixtures.project("pluto-web")
        var mine = OperatorUIFixtures.task("Mine", project: project.id, windowId: nil, operated: nil)
        mine.windowId = "w-\(mine.id)"
        let (controller, daemon) = try controller(run)
        defer { controller.shutdown() }
        controller.workspace.mutate { state in state.append(project: project); state.tasks = [mine] }
        controller.live.sessions = [OperatorUIFixtures.tab("s1", of: mine, .needsInput, active: true)]
        await controller.choose(task: mine.id)?.value
        #expect(activated(daemon) == [mine.windowId])
        #expect(daemon.requests("session.activate").isEmpty)
    }

    /// A task an operator drives whose window you closed comes back on a click or ↩ from the operator
    /// controller — its conversation resumed — finished or not; never from the window reconciler, which
    /// would plan a fresh agent beside it (integration decision 7).
    @Test func aDrivenTaskWithoutAWindowIsAskedBackFromTheOperatorController() async throws {
        let run = OperatorUIFixtures.run()
        let (controller, daemon) = try controller(run)
        defer { controller.shutdown() }
        let project = OperatorUIFixtures.project("pluto-cms")
        let working = OperatorUIFixtures.task("Schema", project: project.id, windowId: nil,
                                              operated: OperatorUIFixtures.operated(run: run.id, key: "a", state: .working))
        let accepted = OperatorUIFixtures.task("Footer", project: project.id, windowId: nil,
                                               operated: OperatorUIFixtures.operated(run: run.id, key: "b", state: .accepted,
                                                                                     sha: "4f2a91c"))
        controller.workspace.mutate { state in state.append(project: project); state.tasks += [working, accepted] }
        var asked: [UUID] = [], restored: [RowSelection] = []
        controller.focus.onChoosingOperatedTaskWithoutWindow { asked.append($0); return nil }
        controller.focus.onChoosingOwedRow { restored.append($0); return nil }
        controller.focus.select(.task(working.id))                 // a click
        controller.focus.browse(.task(accepted.id))
        controller.focus.activateSelection()                       // ↩, on a finished one
        #expect(asked == [working.id, accepted.id])
        #expect(restored.isEmpty, "not the reconciler's to restore")
        #expect(controller.focus.selectedTaskId == accepted.id)
        #expect(daemon.requests("window.activate").isEmpty)
    }

    /// Once the operator controller has reopened it, the task's new window is the one raised.
    @Test func theReopenedWorkersWindowIsRaised() async throws {
        let run = OperatorUIFixtures.run()
        let (controller, daemon) = try controller(run)
        defer { controller.shutdown() }
        let project = OperatorUIFixtures.project("pluto-cms")
        let task = OperatorUIFixtures.task("Schema", project: project.id, windowId: nil,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "a", state: .working))
        controller.workspace.mutate { state in state.append(project: project); state.tasks.append(task) }
        controller.focus.onChoosingOperatedTaskWithoutWindow { _ in
            Task { @MainActor in controller.workspace.mutate { $0.tasks[0].windowId = "worker-window" } }
        }
        await controller.focus.select(.task(task.id))?.value
        #expect(activated(daemon) == ["worker-window"])
    }

    @Test func theOperatorsWindowComingForwardSelectsItsRow() throws {
        let run = OperatorUIFixtures.run(windowId: "operator-window")
        let (controller, _) = try controller(run)
        defer { controller.shutdown() }
        controller.focus.windowActivated("operator-window")
        #expect(controller.focus.selection == .operation(run.id))
    }

    /// One definition of the broadcast that has not ended (`AppState.activeRun`): a broadcast being ended —
    /// its intent stopped before its state — has no group, so the list's selection, ↑ ↓, a click and its
    /// window coming forward never resolve to either of its rows.
    @Test func aBroadcastBeingEndedIsNoLongerAGroup() throws {
        let run = OperatorUIFixtures.run(windowId: "operator-window")
        let (controller, _) = try controller(run)
        defer { controller.shutdown() }
        controller.focus.browse(.operation(run.id))
        controller.workspace.mutate { $0.runs[0].intent = .stopped }
        #expect(controller.state.activeRun == nil)
        #expect(controller.operatorController.activeRun == nil)
        #expect(controller.rows.broadcast == nil)
        #expect(controller.focus.row(id: run.id) == nil, "↑ ↓ cannot reach its header")
        #expect(controller.focus.row(id: OperatorRow.id(of: run.id)) == nil, "nor its Operator's row")
        #expect(controller.focus.selection == nil, "the selection goes with the row")
        controller.focus.windowActivated("operator-window")
        #expect(controller.focus.selection == nil, "its window coming forward selects nothing")
        controller.openBoard(run.id)
        #expect(controller.sheet == nil, "nor does its button open its board")
    }

    @Test func anEndedBroadcastIsNoLongerARow() throws {
        let run = OperatorUIFixtures.run()
        let (controller, _) = try controller(run)
        defer { controller.shutdown() }
        controller.focus.browse(.operation(run.id))
        controller.workspace.mutate { $0.runs[0].state = .stopped }
        #expect(controller.focus.selection == nil, "the selection goes with the row")
        #expect(controller.targetProject == nil)
    }

    /// The reconciler would open a fresh agent in a window it plans for a task; a driven task's worker
    /// is resumed by the operator controller instead, so even asked directly it plans nothing.
    @Test func theReconcilerNeverRestoresADrivenTask() async throws {
        let run = OperatorUIFixtures.run()
        let (controller, daemon) = try controller(run)
        defer { controller.shutdown() }
        let project = OperatorUIFixtures.project("pluto-cms")
        let driven = OperatorUIFixtures.task("Schema", project: project.id, windowId: nil,
                                             operated: OperatorUIFixtures.operated(run: run.id, key: "a", state: .working))
        controller.workspace.mutate { state in state.append(project: project); state.tasks.append(driven) }
        controller.helper.handle(.snapshot(AppControllerTests.emptySnapshot))
        #expect(controller.windows.choose(.task(driven.id)) == nil)
        #expect(controller.windows.restore(.task(driven.id)) == nil)
        #expect(daemon.requests("window.createTask").isEmpty)
    }

    /// A project left with only the Operator's tasks is empty: no chevron, and ↩ on its header opens its menu,
    /// not a fold. Remove Project's question says what the Operator holds there; the header itself says nothing of it.
    @Test func aProjectWithOnlyTheOperatorsTasksIsEmpty() throws {
        let run = OperatorUIFixtures.run()
        let project = OperatorUIFixtures.project("pluto-web")
        let held = OperatorUIFixtures.task("Held", project: project.id, windowId: "w1",
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "a", state: .working))
        let (controller, _) = try controller(run)
        defer { controller.shutdown() }
        controller.workspace.mutate { state in state.append(project: project); state.tasks = [held] }
        let section = try #require(controller.rows.sections.first)
        #expect(section.isEmpty && section.collapsed)
        #expect(!ProjectHeaderRow.collapses(section, canChangeWorkspace: true))
        #expect(section.operatorHelp == "The Operator holds 1 worktree in this project.")
        controller.toggleCollapsed(project)
        #expect(controller.state.project(id: project.id)?.collapsed == false, "nothing to fold")
        #expect(ProjectActions.removalDetail(tasks: 3, archived: [], operatorWorktrees: 2)
                == "Removes the project and its 3 tasks from AiTerm. Files, worktrees and windows are kept. "
                    + "The Operator holds 2 worktrees in this project.")
    }
}
