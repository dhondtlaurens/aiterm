import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The OPERATORS group is derived with the rest of the rows: from the runs and what the Operator is
/// acting on, again whenever one of them changes, and folded by the sidebar alone.
@MainActor
struct OperatorProjectionTests {
    /// A source's value a test moves between derivations, which a captured `var` cannot be.
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private func controller() throws -> AppController {
        let controller = AppController(preferences: .scratch())
        try controller.loadWorkspace()
        return controller
    }

    @Test func theGroupFollowsTheBroadcasts() throws {
        let controller = try controller(), rows = controller.rows
        rows.refresh()
        #expect(rows.operatorSections.isEmpty, "no broadcast yet")

        let run = OperatorUIFixtures.run()
        controller.workspace.mutate { $0.runs = [run] }
        #expect(rows.operatorSections.map(\.id) == [OperatorSection.key])
        #expect(rows.operatorSections[0].operations.map(\.id) == [run.id], "a workspace change derives the group again")
        #expect(rows.runs[run.id] == run)
    }

    @Test func foldingAnOperatorIsTheSidebarsAndSavesNothing() throws {
        let controller = try controller(), rows = controller.rows
        controller.workspace.mutate { $0.runs = [OperatorUIFixtures.run()] }
        let saved = controller.state
        rows.toggleCollapsed(operator: OperatorSection.key)
        #expect(rows.operatorSections[0].collapsed)
        #expect(controller.state == saved)
        rows.toggleCollapsed(operator: OperatorSection.key)
        #expect(!rows.operatorSections[0].collapsed)
    }

    @Test func whatTheOperatorActsOnRedrawsTheTaskItDrives() throws {
        let controller = try controller(), rows = controller.rows
        let project = OperatorUIFixtures.project("pluto-web"), run = OperatorUIFixtures.run()
        let task = OperatorUIFixtures.task("The homepage section", project: project.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "pluto-232", state: .working))
        let acting = Box<Set<UUID>>([])
        rows.actingSource = { acting.value }
        controller.workspace.mutate { state in state.append(project: project); state.tasks = [task]; state.runs = [run] }
        #expect(rows.sections[0].tasks[0].avatars.operatorPresence == .driving)
        acting.value = [task.id]
        rows.refresh()
        #expect(rows.sections[0].tasks[0].avatars.operatorPresence == .acting)
        #expect(rows.acting == [task.id])
    }

    // -- each input alone re-derives the rows ----------------------------------------

    @Test func aChangeOnlyToTheRunsDerivesTheSectionsAndTheDrivenRowAgain() throws {
        let controller = try controller(), rows = controller.rows
        let project = OperatorUIFixtures.project("pluto-web"), run = OperatorUIFixtures.run()
        let task = OperatorUIFixtures.task("The homepage section", project: project.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "pluto-232", state: .working))
        controller.workspace.mutate { state in state.append(project: project); state.tasks = [task]; state.runs = [run] }
        #expect(rows.operatorSections[0].operations.map(\.id) == [run.id])
        #expect(rows.sections[0].tasks[0].avatars.operatorPresence == .driving)

        // The tasks, the items and the sessions stay as they were: only the run's state moves.
        var stopped = run
        stopped.state = .stopped
        let before = rows.derivations
        controller.workspace.mutate { $0.runs = [stopped] }
        #expect(rows.derivations == before + 1, "a runs-only change is a change to the rows")
        #expect(rows.runs[run.id]?.state == .stopped)
        #expect(rows.operatorSections.isEmpty, "an ended broadcast leaves the group, and with none running so does its header")
        #expect(rows.sections[0].tasks[0].avatars.operatorPresence == nil, "and the task it drove loses the operator's mark")
    }

    @Test func aChangeOnlyToWhatTheOperatorActsOnDerivesTheDrivenRowAgain() throws {
        let controller = try controller(), rows = controller.rows
        let project = OperatorUIFixtures.project("pluto-web"), run = OperatorUIFixtures.run()
        let task = OperatorUIFixtures.task("The homepage section", project: project.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "pluto-232", state: .working))
        controller.workspace.mutate { state in state.append(project: project); state.tasks = [task]; state.runs = [run] }
        #expect(rows.sections[0].tasks[0].avatars.operatorPresence == .driving)

        // Through the operator controller's own hook, as the tool handler reports it.
        let before = rows.derivations
        controller.operatorController.setActing(task.id, true)
        #expect(rows.derivations == before + 1, "acting alone is a change to the rows")
        #expect(rows.acting == [task.id])
        #expect(rows.sections[0].tasks[0].avatars.operatorPresence == .acting)

        controller.operatorController.setActing(task.id, false)
        #expect(rows.acting.isEmpty)
        #expect(rows.sections[0].tasks[0].avatars.operatorPresence == .driving)
    }

    @Test func runsWithTheSameIdDoNotTrapTheLookup() throws {
        let controller = try controller(), rows = controller.rows
        let run = OperatorUIFixtures.run()
        var twin = run
        twin.name = "Same id, another name"
        controller.workspace.mutate { $0.runs = [run, twin] }
        #expect(rows.runs[run.id] == run, "the first run with an id wins")
    }
}
