import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// An operation's row opens its chat — the operator's window — by the rules a task row follows: a
/// click or ↩ brings it forward with iTerm2, ↑ ↓ peek with the keyboard left in the sidebar, and a
/// window you closed comes back on the click (spec §10.3).
@MainActor
struct OperationRowFocusTests {
    private func controller(_ run: OperatorRun, failing: [String: DaemonError.Code] = [:]) throws -> (AppController, RecordingDaemon) {
        let controller = AppController(preferences: .scratch())
        try controller.loadWorkspace()
        controller.workspace.mutate { $0.runs = [run] }
        let daemon = RecordingDaemon(failing: failing)
        controller.helper.setDaemonClient(daemon)
        return (controller, daemon)
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
        controller.focus.onChoosingOperationWithoutWindow { asked.append($0); return nil }
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
        controller.focus.onChoosingOperationWithoutWindow { asked.append($0); return nil }
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
