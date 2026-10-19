import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The OPERATORS group as values: the Operator's header with its broadcasts under it, and each
/// operation's row — the agents at work in it, its progress or its state, and what waits on you —
/// the operation's state, never the operator session's, so an idle operator over a stuck operation
/// cannot look calm (spec §10.1, §10.3).
@Suite struct OperatorSectionsTests {
    private let cms = OperatorUIFixtures.project("pluto-cms"), web = OperatorUIFixtures.project("pluto-web")

    private func state(_ runs: [OperatorRun], _ tasks: [TaskItem] = []) -> AppState {
        var state = AppState()
        state.runs = runs
        state.tasks = tasks
        return state
    }

    private func task(_ title: String, run: UUID, _ state: OperatedState, agent: AgentKind = .claude, id: UUID = UUID(),
                      takenOver: Bool = false, flags: Set<OperatedFlag> = []) -> TaskItem {
        OperatorUIFixtures.task(title, id: id, agent: agent, project: web.id,
                                operated: OperatorUIFixtures.operated(run: run, key: title, state: state,
                                                                      sha: SidebarModel.isFinished(state) ? "4f2a91c00" : nil,
                                                                      takenOver: takenOver, flags: flags))
    }

    @Test func theOperatorIsOneHeaderWithItsBroadcastsUnderIt() {
        let signup = OperatorUIFixtures.run(name: "Newsletter signup"), nuxt = OperatorUIFixtures.run(name: "Nuxt upgrade")
        let ended = OperatorUIFixtures.run(name: "Last week's", state: .stopped)
        let sections = SidebarModel.operatorSections(state: state([signup, nuxt, ended]))
        #expect(sections.map(\.id) == [OperatorSection.key])
        #expect(sections[0].name == "Operator")
        #expect(sections[0].operations.map(\.name) == ["Newsletter signup", "Nuxt upgrade"], "an ended broadcast leaves the group")
        #expect(!sections[0].collapsed)
    }

    @Test func withNoBroadcastRunningThereIsNoSection() {
        #expect(SidebarModel.operatorSections(state: state([])).isEmpty)
        #expect(SidebarModel.operatorSections(state: state([OperatorUIFixtures.run(state: .stopped)])).isEmpty)
    }

    @Test func aFoldedOperatorDrawsCollapsed() {
        let sections = SidebarModel.operatorSections(state: state([OperatorUIFixtures.run()]), folded: [OperatorSection.key])
        #expect(sections[0].collapsed)
        #expect(sections[0].operations.count == 1)
    }

    /// The design's operation: one done, three at work, Codex asking about npm install, and a question
    /// for you about the whole of it.
    @Test func anOperationsRowCountsItsProgressAndWhatWaitsOnYou() {
        let footer = UUID()
        let run = OperatorUIFixtures.run(questions: [
            OperatorUIFixtures.question("Codex asks to run npm install", task: footer),
            OperatorUIFixtures.question("Should the block be on every page?"),
        ])
        let tasks = [task("schema", run: run.id, .accepted),
                     task("homepage", run: run.id, .working),
                     task("footer", run: run.id, .working, agent: .codex, id: footer, flags: [.waitingOnYou]),
                     task("nuxt", run: run.id, .working, agent: .codex),
                     task("dropped", run: run.id, .stopped)]
        let row = SidebarModel.operationRow(run: run, tasks: tasks)
        #expect(row.caption == "1 of 4 done", "a stopped task is not counted")
        #expect(row.showsProgress && !row.captionWarns)
        #expect(row.attention == 2, "the footer's question counts once, not again for its flag")
        #expect(row.status == .needsInput)
        #expect(row.avatars == AvatarGroup(marks: [.claude, .codex], overflow: 0), "each agent at work once")
    }

    @Test func aFinishedTasksLeftoverFlagAsksNothingOfYou() {
        let run = OperatorUIFixtures.run()
        let row = SidebarModel.operationRow(run: run, tasks: [task("a", run: run.id, .accepted, flags: [.waitingOnYou]),
                                                               task("b", run: run.id, .blocked)])
        #expect(row.attention == 1, "only the blocked task waits on you")
    }

    @Test func aCalmOperationIsWorkingOrIdle() {
        let run = OperatorUIFixtures.run()
        #expect(SidebarModel.operationRow(run: run, tasks: [task("a", run: run.id, .working)]).status == .working)
        #expect(SidebarModel.operationRow(run: run, tasks: [task("a", run: run.id, .queued)]).status == .idle)
        #expect(SidebarModel.operationRow(run: run, tasks: [task("a", run: run.id, .working, takenOver: true)]).avatars
                == AvatarGroup(marks: [], overflow: 0), "a task you took over is yours, not the operation's")
    }

    @Test func theOperationsStateSaysMoreThanItsProgressWhenItCan() {
        func row(_ run: OperatorRun, _ tasks: [TaskItem] = []) -> (String, Bool, Bool, TaskStatus) {
            let row = SidebarModel.operationRow(run: run, tasks: tasks)
            return (row.caption, row.captionWarns, row.showsProgress, row.status)
        }
        let waiting = OperatorUIFixtures.run(planRevision: 2, approvedRevision: 1)
        #expect(row(waiting) == ("plan waits for you", true, false, .needsInput))
        let approved = OperatorUIFixtures.run(planRevision: 2, approvedRevision: 2)
        #expect(row(approved) == ("0 of 0 done", false, true, .idle), "an approved plan no longer waits")
        #expect(row(OperatorUIFixtures.run(state: .planning, planRevision: 0, approvedRevision: nil)) == ("planning", false, false, .working))
        let paused = OperatorUIFixtures.run(state: .paused)
        #expect(row(paused, [task("a", run: paused.id, .working), task("b", run: paused.id, .working)])
                == ("paused · 2 workers still running", false, false, .idle))
        #expect(row(paused, [task("a", run: paused.id, .working)]) == ("paused · 1 worker still running", false, false, .idle))
        #expect(row(paused) == ("paused", false, false, .idle))
        #expect(row(OperatorUIFixtures.run(state: .operatorOffline)) == ("operator offline", true, false, .needsInput))
        let complete = OperatorUIFixtures.run(state: .complete)
        #expect(row(complete, (0..<4).map { task("t\($0)", run: complete.id, .accepted) }) == ("done · 4 of 4", false, false, .done))
    }

    @Test func agentsAtWorkPastTwoTurnTheSecondPlaceIntoACount() {
        let run = OperatorUIFixtures.run()
        let row = SidebarModel.operationRow(run: run, tasks: [task("a", run: run.id, .working),
                                                               task("b", run: run.id, .working, agent: .codex),
                                                               task("c", run: run.id, .working, agent: .grok)])
        #expect(row.avatars == AvatarGroup(marks: [.claude], overflow: 2))
    }

    @Test func aFoldedOperatorCountsItsOperationsByState() {
        let run = OperatorUIFixtures.run(), waiting = OperatorUIFixtures.run(planRevision: 2, approvedRevision: 1)
        let rows = [SidebarModel.operationRow(run: run, tasks: [task("a", run: run.id, .working)]),
                    SidebarModel.operationRow(run: waiting, tasks: [])]
        #expect(SidebarModel.operationStatusCounts(rows) == [StatusCount(status: .working, count: 1),
                                                             StatusCount(status: .needsInput, count: 1)])
    }
}
