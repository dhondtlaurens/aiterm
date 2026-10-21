import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The broadcast row is derived with the rest of the rows: from the runs, their tasks and what the
/// Operator is acting on, again whenever one of them changes.
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

    @Test func theRowFollowsTheBroadcast() throws {
        let controller = try controller(), rows = controller.rows
        rows.refresh()
        #expect(rows.broadcast == nil, "no broadcast yet")

        let run = OperatorUIFixtures.run()
        controller.workspace.mutate { $0.runs = [run] }
        #expect(rows.broadcast?.id == run.id, "a workspace change derives the row again")
        #expect(rows.broadcast?.title == run.name)
        #expect(rows.runs[run.id] == run)
    }

    @Test func whatTheOperatorDoesIsTheBroadcastsLine() throws {
        let controller = try controller(), rows = controller.rows
        let project = OperatorUIFixtures.project("pluto-web"), run = OperatorUIFixtures.run()
        let task = OperatorUIFixtures.task("The homepage section", project: project.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "pluto-232", state: .queued))
        let acting = Box<OperatorActs>(.none)
        rows.actingSource = { acting.value }
        controller.workspace.mutate { state in state.append(project: project); state.tasks = [task]; state.runs = [run] }
        #expect(rows.broadcast?.status == .idle)
        acting.value = OperatorActs(runs: [run.id: .init(act: .starting, task: "pluto-232")])
        rows.refresh()
        #expect(rows.broadcast?.line.text == "starting Claude · The homepage section")
        #expect(rows.broadcast?.status == .working)
    }

    /// The tabs are read for the broadcast's line too: a task whose worker ended its turn waits to be accepted,
    /// on the row and the board's band alike.
    @Test func aWorkerThatEndedItsTurnIsReadyToAcceptOnTheBroadcastsLine() throws {
        let controller = try controller(), rows = controller.rows
        let project = OperatorUIFixtures.project("pluto-web"), run = OperatorUIFixtures.run()
        let task = OperatorUIFixtures.task("The homepage section", project: project.id, windowId: "w9",
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "pluto-232", state: .working))
        controller.workspace.mutate { state in state.append(project: project); state.tasks = [task]; state.runs = [run] }
        func worker(_ state: SessionState) -> SessionInfo {
            SessionInfo(sessionId: "w1", windowId: "w9", tabIndex: 0, taskId: task.id.uuidString, projectId: project.id.uuidString,
                        agent: .claude, model: nil, state: state, title: "", cwd: "/")
        }
        controller.live.sessions = [worker(.working)]
        #expect(rows.broadcast?.line == OperatorLine("working · 1 task", look: .acting))
        controller.live.sessions = [worker(.idle)]
        #expect(rows.broadcast?.line == OperatorLine("ready to accept · 1 task"))
        #expect(rows.board?.band == OperatorLine("ready to accept · 1 task"))
    }

    @Test func whatTheOperatorActsOnRedrawsTheTaskItDrives() throws {
        let controller = try controller(), rows = controller.rows
        let project = OperatorUIFixtures.project("pluto-web"), run = OperatorUIFixtures.run()
        let task = OperatorUIFixtures.task("The homepage section", project: project.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "pluto-232", state: .working))
        let acting = Box<OperatorActs>(.none)
        rows.actingSource = { acting.value }
        controller.workspace.mutate { state in state.append(project: project); state.tasks = [task]; state.runs = [run] }
        #expect(rows.sections[0].tasks[0].operatorLine == OperatorLine("working", look: .acting))
        acting.value = OperatorActs(tasks: [task.id: .answering])
        rows.refresh()
        #expect(rows.sections[0].tasks[0].operatorLine == OperatorLine("answering Claude", look: .acting))
        #expect(rows.acting.tasks == [task.id: .answering])
    }

    // -- each input alone re-derives the rows ----------------------------------------

    @Test func aChangeOnlyToTheRunsDerivesTheSectionsAndTheDrivenRowAgain() throws {
        let controller = try controller(), rows = controller.rows
        let project = OperatorUIFixtures.project("pluto-web"), run = OperatorUIFixtures.run()
        let task = OperatorUIFixtures.task("The homepage section", project: project.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "pluto-232", state: .working))
        controller.workspace.mutate { state in state.append(project: project); state.tasks = [task]; state.runs = [run] }
        #expect(rows.broadcast?.id == run.id)
        #expect(rows.sections[0].tasks[0].operatorLine != nil)

        // The tasks, the items and the sessions stay as they were: only the run's state moves.
        var stopped = run
        stopped.state = .stopped
        let before = rows.derivations
        controller.workspace.mutate { $0.runs = [stopped] }
        #expect(rows.derivations == before + 1, "a runs-only change is a change to the rows")
        #expect(rows.runs[run.id]?.state == .stopped)
        #expect(rows.broadcast == nil, "an ended broadcast has no row")
        #expect(rows.sections[0].tasks[0].operatorLine == nil, "and the task it drove loses the Operator's line")
    }

    @Test func aChangeOnlyToWhatTheOperatorActsOnDerivesTheDrivenRowAgain() throws {
        let controller = try controller(), rows = controller.rows
        let project = OperatorUIFixtures.project("pluto-web"), run = OperatorUIFixtures.run()
        let task = OperatorUIFixtures.task("The homepage section", project: project.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "pluto-232", state: .working))
        controller.workspace.mutate { state in state.append(project: project); state.tasks = [task]; state.runs = [run] }
        #expect(rows.sections[0].tasks[0].operatorLine == OperatorLine("working", look: .acting))

        // Through the operator controller's own hook, as the tool handler reports it.
        let before = rows.derivations
        let answering = OperatorActivity(run: run.id, task: task.id, act: .answering)
        controller.operatorController.setActing(answering, true)
        #expect(rows.derivations == before + 1, "acting alone is a change to the rows")
        #expect(rows.acting.tasks == [task.id: .answering])
        #expect(rows.acting.broadcast(run.id)?.0 == .answering && rows.acting.broadcast(run.id)?.task == "pluto-232")
        #expect(rows.sections[0].tasks[0].operatorLine?.look == .acting)

        controller.operatorController.setActing(answering, false)
        #expect(rows.acting == .none)
        #expect(rows.sections[0].tasks[0].operatorLine == OperatorLine("working", look: .acting))
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
