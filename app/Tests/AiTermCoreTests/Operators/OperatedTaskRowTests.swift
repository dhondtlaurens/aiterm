import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// A task the Operator drives draws its own agents, as any task does, and the Operator's status line as
/// its third line (`OperatorLine`), until the Operator lets go: you took it over, it was stopped, or the
/// broadcast ended (spec §7, §13). While the broadcast lives the row is drawn in its group; once it has ended,
/// in its project again.
@Suite struct OperatedTaskRowTests {
    private let web = OperatorUIFixtures.project("pluto-web")

    private func tab(_ task: TaskItem, _ agent: SessionAgent, number: Int = 0) -> SessionInfo {
        SessionInfo(sessionId: "\(task.id)-\(number)", windowId: "w", tabIndex: number, taskId: task.id.uuidString,
                    projectId: nil, agent: agent, model: nil, state: .working, title: "", cwd: task.worktreePath)
    }

    private func row(_ task: TaskItem, run: OperatorRun, tabs: [SessionInfo] = [], acting: [UUID: OperatorAct] = [:]) -> TaskRow {
        var state = AppState()
        state.append(project: web)
        state.tasks = [task]
        state.runs = [run]
        if let held = SidebarModel.broadcastSection(state: state, sessions: tabs, acting: OperatorActs(tasks: acting))?.tasks.first {
            return held
        }
        return SidebarModel.sections(state: state, sessions: tabs, branchByCwd: [:], projectBranch: [:], acting: acting)[0].tasks[0]
    }

    @Test func itsAvatarsAreItsOwnAgentsAndTheOperatorSpeaksOnItsLine() {
        let run = OperatorUIFixtures.run()
        let task = OperatorUIFixtures.task("The homepage section", jira: "PLUTO-232", project: web.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "pluto-232", state: .working))
        let drawn = row(task, run: run, tabs: [tab(task, .claude)])
        #expect(drawn.avatars == AvatarGroup(marks: [.claude], overflow: 0))
        #expect(drawn.operatorLine == OperatorLine("Operator watching", look: .acting))
        let acting = row(task, run: run, tabs: [tab(task, .claude)], acting: [task.id: .answering])
        #expect(acting.operatorLine == OperatorLine("Operator answering", look: .acting))
    }

    /// The column is two marks wide, all of it the task's own: a third tab is `+n`.
    @Test func threeTabsFillTheTwoMarkColumnAsAnyTasksDo() {
        let run = OperatorUIFixtures.run()
        let task = OperatorUIFixtures.task("t", project: web.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "t", state: .working))
        let tabs = [tab(task, .claude, number: 0), tab(task, .codex, number: 1), tab(task, .shell, number: 2)]
        #expect(row(task, run: run, tabs: tabs).avatars == AvatarGroup(marks: [.claude], overflow: 2))
    }

    @Test func theLineGoesWhenTheOperatorLetsGo() {
        let run = OperatorUIFixtures.run()
        for operated in [OperatorUIFixtures.operated(run: run.id, key: "mine", state: .working, takenOver: true),
                         OperatorUIFixtures.operated(run: run.id, key: "stopped", state: .stopped)] {
            let task = OperatorUIFixtures.task("t", project: web.id, operated: operated)
            #expect(row(task, run: run).operatorLine == nil, "\(operated.key)")
        }
        let done = OperatorUIFixtures.task("t", project: web.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "done", state: .accepted, sha: "4f2a91c0"))
        #expect(row(done, run: run).operatorLine == OperatorLine("done · 4f2a91c", look: .ended), "a done task keeps its line while the broadcast runs")
        let ended = OperatorUIFixtures.run(state: .stopped)
        let task = OperatorUIFixtures.task("t", project: web.id,
                                           operated: OperatorUIFixtures.operated(run: ended.id, key: "t", state: .working))
        #expect(row(task, run: ended).operatorLine == nil, "an ended broadcast says nothing")
    }

    @Test func aTaskYouMadeYourselfIsDrawnAsItAlwaysWas() {
        let task = OperatorUIFixtures.task("Mine", project: web.id, operated: nil)
        let drawn = row(task, run: OperatorUIFixtures.run())
        #expect(drawn.operatorLine == nil)
        #expect(drawn.avatars == AvatarGroup(marks: [], overflow: 0))
    }

    /// A question about a task must remain visible on that task, as well as on the Operator.
    @Test func aQuestionOnTheTaskMarksItsLineWaitingOnYou() throws {
        let footerId = UUID()
        let run = OperatorUIFixtures.run(questions: [OperatorUIFixtures.question("retry policy?", task: footerId)])
        let task = OperatorUIFixtures.task("Fix the /privacy footer link", id: footerId, agent: .codex, project: web.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "footer", state: .working,
                                                                                  flags: [.waitingOnYou]))
        let line = row(task, run: run).operatorLine
        #expect(line?.text == "waiting on you" && line?.look == .needsYou)
        #expect(row(task, run: run).status == .needsInput)
        let parent = OperatorUIFixtures.task("The signup block schema", jira: "PLUTO-231", project: web.id,
                                             operated: OperatorUIFixtures.operated(run: run.id, key: "pluto-231", state: .accepted, sha: "4f2a91c"))
        let child = OperatorUIFixtures.task("t", project: web.id,
                                            operated: OperatorUIFixtures.operated(run: run.id, key: "t", state: .queued,
                                                                                   dependsOn: [TaskDependency(task: parent.id, kind: .order)]))
        var state = AppState()
        state.append(project: web)
        state.tasks = [parent, child]
        state.runs = [run]
        let rows = try #require(SidebarModel.broadcastSection(state: state, sessions: [])).tasks
        #expect(rows.map(\.operatorLine?.text) == ["done · 4f2a91c", "queued · after PLUTO-231"])
    }
}
