import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The broadcast row: ↑ ↓ peek at the Operator's window as a task row's arrows do; a click or ↩ opens
/// the overview, and with the Operator's window closed reopens it behind the sheet (spec §3, §9). Its
/// selection reaches the Operator's window by the rules a task row's follows.
@MainActor
struct BroadcastRowFocusTests {
    private func controller(_ run: OperatorRun, failing: [String: DaemonError.Code] = [:]) throws -> (AppController, RecordingDaemon) {
        let controller = AppController(preferences: .scratch())
        try controller.loadWorkspace()
        controller.workspace.mutate { $0.runs = [run] }
        let daemon = RecordingDaemon(failing: failing)
        controller.helper.setDaemonClient(daemon)
        return (controller, daemon)
    }

    @Test func clickOpensTheBoardAndArrowsPeek() async throws {
        let run = OperatorUIFixtures.run(windowId: "operator-window")
        let (controller, daemon) = try controller(run)
        defer { controller.shutdown() }
        var activated = 0
        // Its tab is listed: the Operator's window is really open.
        controller.live.sessions = [Self.operatorTab(of: run)]
        controller.focus.onChoosingOperationWithoutWindow { _, _ in Issue.record("its window is open"); return nil }
        // ↓ onto the row: the Operator's window comes forward beside the sidebar; nothing opens.
        await controller.focus.peek(id: run.id)?.value
        #expect(daemon.requests("window.activate").map { $0.params["windowId"] as? String } == ["operator-window"])
        #expect(controller.sheet == nil, "a peek only looks")
        activated = daemon.requests("window.activate").count

        // A click: the overview, over the sidebar; the window it peeked at stays where it is.
        await controller.openBroadcast(run.id)?.value
        guard case .broadcastBoard(let clicked)? = controller.sheet else { Issue.record("no board on a click"); return }
        #expect(clicked == run.id)
        #expect(controller.focus.selection == .operation(run.id))
        #expect(daemon.requests("window.activate").count == activated, "the sheet is what comes forward")

        // ↩ on the selected row does what the click does.
        controller.sheets.sheet = nil
        await controller.activateSelection()?.value
        guard case .broadcastBoard(let returned)? = controller.sheet else { Issue.record("no board on ↩"); return }
        #expect(returned == run.id)
        #expect(daemon.requests("window.activate").count == activated)
    }

    /// With the Operator's window closed the click also asks it back from the operator controller, which
    /// reopens it behind the sheet and resumes the broadcast. Closed is what the listed tabs say, not the
    /// recorded window id: a window closed before AiTerm heard is asked back too. Until iTerm2's tabs are
    /// known, the recorded id is all there is.
    @Test func aClickWithTheWindowClosedReopensItBehindTheBoard() async throws {
        for windowId in [nil, "operator-window"] {
            let run = OperatorUIFixtures.run(windowId: windowId)
            let (controller, daemon) = try controller(run)
            defer { controller.shutdown() }
            // iTerm2's whole list, without the Operator's tab.
            if windowId != nil { controller.operatorController.handle(.snapshot(AppControllerTests.emptySnapshot)) }
            var asked: [String] = []
            controller.focus.onChoosingOperationWithoutWindow { id, behind in
                asked.append("\(id == run.id ? "the broadcast" : "another")\(behind ? ", behind" : ", in front")"); return nil
            }
            controller.openBroadcast(run.id)
            #expect(asked == ["the broadcast, behind"], "recorded window \(windowId ?? "none")")
            guard case .broadcastBoard(let id)? = controller.sheet else { Issue.record("no board"); return }
            #expect(id == run.id)
            #expect(controller.focus.selection == .operation(run.id))
            #expect(daemon.requests("window.activate").isEmpty)
        }
    }

    /// A window id recorded while iTerm2's tabs are not known yet is taken at its word: the click only opens the board.
    @Test func aRecordedWindowIsTakenAtItsWordUntilTheTabsAreKnown() throws {
        let run = OperatorUIFixtures.run(windowId: "operator-window")
        let (controller, _) = try controller(run)
        defer { controller.shutdown() }
        controller.focus.onChoosingOperationWithoutWindow { _, _ in Issue.record("its tabs are not known yet"); return nil }
        #expect(controller.openBroadcast(run.id) == nil)
        guard case .broadcastBoard? = controller.sheet else { Issue.record("no board"); return }
    }

    /// The Operator's tab as iTerm2 lists it: tagged with the broadcast, in its window.
    static func operatorTab(of run: OperatorRun) -> SessionInfo {
        SessionInfo(sessionId: "op", windowId: run.operatorWindowId ?? "operator-window", tabIndex: 0, taskId: run.id.uuidString,
                    projectId: nil, agent: .claude, model: nil, state: .working, title: "", cwd: "/")
    }

    @Test func choosingAnOperationBringsItsOperatorsWindowForward() async throws {
        let run = OperatorUIFixtures.run(windowId: "operator-window")
        let (controller, daemon) = try controller(run)
        defer { controller.shutdown() }
        #expect(controller.focus.row(id: run.id) == .operation(run.id))
        await controller.focus.select(.operation(run.id))?.value
        #expect(controller.focus.selectedOperationId == run.id)
        #expect(daemon.requests("window.activate").map { $0.params["windowId"] as? String } == ["operator-window"])
    }

    @Test func aWindowYouClosedIsAskedBackFromTheOperatorController() async throws {
        let run = OperatorUIFixtures.run(windowId: nil)
        let (controller, daemon) = try controller(run)
        defer { controller.shutdown() }
        var asked: [UUID] = []
        controller.focus.onChoosingOperationWithoutWindow { id, _ in asked.append(id); return nil }
        controller.focus.select(.operation(run.id))
        #expect(asked == [run.id])
        #expect(controller.focus.selectedOperationId == run.id)
        #expect(daemon.requests("window.activate").isEmpty)
    }

    /// A window closed before the app heard — its id still recorded, iTerm2 answering "not found" —
    /// comes back on the click too, as a missing one does. A peek never reopens anything.
    @Test func aWindowThatTurnsOutGoneIsAskedBackToo() async throws {
        let run = OperatorUIFixtures.run(windowId: "operator-window")
        let (controller, daemon) = try controller(run, failing: ["window.activate": .notFound])
        defer { controller.shutdown() }
        var asked: [UUID] = []
        controller.focus.onChoosingOperationWithoutWindow { id, _ in asked.append(id); return nil }
        await controller.focus.peek(.operation(run.id))?.value
        #expect(asked.isEmpty, "a peek only looks")
        await controller.focus.select(.operation(run.id))?.value
        #expect(asked == [run.id])
        #expect(daemon.requests("window.activate").count == 2)
        #expect(controller.focus.selectedOperationId == run.id)
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
        #expect(daemon.requests("window.activate").map { $0.params["windowId"] as? String } == ["worker-window"])
    }

    @Test func theOperatorsWindowComingForwardSelectsItsRow() throws {
        let run = OperatorUIFixtures.run(windowId: "operator-window")
        let (controller, _) = try controller(run)
        defer { controller.shutdown() }
        controller.focus.windowActivated("operator-window")
        #expect(controller.focus.selection == .operation(run.id))
    }

    /// One definition of the broadcast that has not ended (`AppState.activeRun`): a broadcast being ended —
    /// its intent stopped before its state — has no row, so the list's selection, ↑ ↓, a click and its
    /// window coming forward never resolve to it.
    @Test func aBroadcastBeingEndedIsNoLongerARow() throws {
        let run = OperatorUIFixtures.run(windowId: "operator-window")
        let (controller, _) = try controller(run)
        defer { controller.shutdown() }
        controller.focus.browse(.operation(run.id))
        controller.workspace.mutate { $0.runs[0].intent = .stopped }
        #expect(controller.state.activeRun == nil)
        #expect(controller.operatorController.activeRun == nil)
        #expect(controller.rows.broadcast == nil)
        #expect(controller.focus.row(id: run.id) == nil, "↑ ↓ cannot reach it")
        #expect(controller.focus.selection == nil, "the selection goes with the row")
        controller.focus.windowActivated("operator-window")
        #expect(controller.focus.selection == nil, "its window coming forward selects nothing")
        #expect(controller.openBroadcast(run.id) == nil)
        #expect(controller.sheet == nil, "nor does a click open its overview")
    }

    @Test func anEndedOperationIsNoLongerARow() throws {
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
}
