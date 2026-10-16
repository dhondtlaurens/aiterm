import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// A task an operator drives wears the operator's mark first among its avatars — breathing while the
/// operator acts on it — and its workflow state as a caption, until the operator lets go: the task is
/// done, or you took it over (spec §10.4).
@Suite struct OperatedTaskRowTests {
    private let web = OperatorUIFixtures.project("pluto-web")

    private func tab(_ task: TaskItem, _ agent: SessionAgent, number: Int = 0) -> SessionInfo {
        SessionInfo(sessionId: "\(task.id)-\(number)", windowId: "w", tabIndex: number, taskId: task.id.uuidString,
                    projectId: nil, agent: agent, model: nil, state: .working, title: "", cwd: task.worktreePath)
    }

    private func row(_ task: TaskItem, run: OperatorRun, tabs: [SessionInfo] = [], acting: Set<UUID> = []) -> TaskRow {
        var state = AppState()
        state.append(project: web)
        state.tasks = [task]
        state.runs = [run]
        let sections = SidebarModel.sections(state: state, sessions: tabs, branchByCwd: [:], projectBranch: [:], acting: acting)
        return sections[0].tasks[0]
    }

    @Test func theOperatorComesFirstWhileItDrivesAndBreathesWhileItActs() {
        let run = OperatorUIFixtures.run()
        let task = OperatorUIFixtures.task("The homepage section", jira: "PLUTO-232", project: web.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "pluto-232", state: .working))
        #expect(row(task, run: run, tabs: [tab(task, .claude)]).avatars
                == AvatarGroup(marks: [.claude], overflow: 0, operatorPresence: .driving))
        #expect(row(task, run: run, tabs: [tab(task, .claude)], acting: [task.id]).avatars.operatorPresence == .acting)
    }

    /// The column is two marks wide: the operator takes one, so a second tab already counts as `+n`.
    @Test func theOperatorAndThreeTabsStillFitTheTwoMarkColumn() {
        let run = OperatorUIFixtures.run()
        let task = OperatorUIFixtures.task("t", project: web.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "t", state: .working))
        let tabs = [tab(task, .claude, number: 0), tab(task, .codex, number: 1), tab(task, .shell, number: 2)]
        #expect(row(task, run: run, tabs: tabs).avatars == AvatarGroup(marks: [], overflow: 3, operatorPresence: .driving))
    }

    @Test func theOperatorLetsGoOfADoneATakenOverOrAStoppedTask() {
        let run = OperatorUIFixtures.run()
        for operated in [OperatorUIFixtures.operated(run: run.id, key: "done", state: .accepted, sha: "4f2a91c0"),
                         OperatorUIFixtures.operated(run: run.id, key: "mine", state: .working, takenOver: true),
                         OperatorUIFixtures.operated(run: run.id, key: "stopped", state: .stopped)] {
            let task = OperatorUIFixtures.task("t", project: web.id, operated: operated)
            #expect(row(task, run: run).avatars.operatorPresence == nil, "\(operated.key)")
        }
        let ended = OperatorUIFixtures.run(state: .stopped)
        let task = OperatorUIFixtures.task("t", project: web.id,
                                           operated: OperatorUIFixtures.operated(run: ended.id, key: "t", state: .working))
        #expect(row(task, run: ended).avatars.operatorPresence == nil, "an ended operation drives nothing")
    }

    @Test func aTaskYouMadeYourselfIsDrawnAsItAlwaysWas() {
        let task = OperatorUIFixtures.task("Mine", project: web.id, operated: nil)
        let drawn = row(task, run: OperatorUIFixtures.run())
        #expect(drawn.operated == nil)
        #expect(drawn.avatars == AvatarGroup(marks: [], overflow: 0))
    }

    @Test func theCaptionSaysWhereTheTaskIsInItsWorkflow() {
        let run = OperatorUIFixtures.run()
        let parent = OperatorUIFixtures.task("The signup block schema", jira: "PLUTO-231", project: web.id,
                                             operated: OperatorUIFixtures.operated(run: run.id, key: "pluto-231", state: .accepted,
                                                                                    sha: "4f2a91cdeadbeef"))
        let footerId = UUID()
        let asking = OperatorUIFixtures.run(id: run.id, questions: [
            OperatorUIFixtures.question("Codex asks to run npm install", task: footerId),
        ])
        func caption(_ operated: OperatedTask, agent: AgentKind = .claude, in run: OperatorRun = run,
                     id: UUID = UUID(), acting: Bool = false) -> OperatedCaption? {
            let task = OperatorUIFixtures.task("t", id: id, agent: agent, project: web.id, operated: operated)
            return SidebarModel.operatedCaption(task: task, run: run, tasks: [parent.id: parent], acting: acting)
        }
        func operated(_ state: OperatedState, end: TaskEnd = .commit, dependsOn: [TaskDependency] = [], stackedOn: UUID? = nil,
                      sha: String? = nil, takenOver: Bool = false, reason: String? = nil,
                      flags: Set<OperatedFlag> = []) -> OperatedTask {
            OperatorUIFixtures.operated(run: run.id, key: "t", state: state, end: end, dependsOn: dependsOn, stackedOn: stackedOn,
                                        sha: sha, takenOver: takenOver, blockedReason: reason, flags: flags)
        }
        #expect(caption(operated(.planned)) == OperatedCaption("planned"))
        #expect(caption(operated(.queued, dependsOn: [TaskDependency(task: parent.id, kind: .code)], stackedOn: parent.id))
                == OperatedCaption("queued · builds on PLUTO-231"))
        #expect(caption(operated(.queued, dependsOn: [TaskDependency(task: parent.id, kind: .order)]))
                == OperatedCaption("queued · after PLUTO-231"))
        #expect(caption(operated(.queued)) == OperatedCaption("queued"))
        #expect(caption(operated(.working)) == OperatedCaption("working"))
        #expect(caption(operated(.working), acting: true) == OperatedCaption("working · the operator is answering Claude"))
        #expect(caption(operated(.working, flags: [.waitingOnYou]), agent: .codex, in: asking, id: footerId)
                == OperatedCaption("waiting on you · Codex asks to run npm install", warns: true))
        #expect(caption(operated(.working, flags: [.waitingOnYou]), agent: .codex)
                == OperatedCaption("waiting on you · Codex needs you", warns: true))
        #expect(caption(operated(.working, flags: [.possiblyStalled])) == OperatedCaption("working · possibly stalled", warns: true))
        #expect(caption(operated(.blocked, reason: "the tests fail on main"))
                == OperatedCaption("blocked · the tests fail on main", warns: true))
        #expect(caption(operated(.failed, reason: "npm ci failed")) == OperatedCaption("failed · npm ci failed", warns: true))
        #expect(caption(operated(.accepted, sha: "4f2a91cdeadbeef")) == OperatedCaption("done · 4f2a91c"))
        #expect(caption(operated(.noChange)) == OperatedCaption("done · no change"))
        #expect(caption(operated(.published, end: .merge, sha: "9b3e07d1234")) == OperatedCaption("merged · 9b3e07d"))
        #expect(caption(operated(.published, end: .draftMR, sha: "9b3e07d1234")) == OperatedCaption("draft MR · 9b3e07d"))
        #expect(caption(operated(.stopped)) == OperatedCaption("stopped"))
        #expect(caption(operated(.working, takenOver: true)) == OperatedCaption("taken over"))
    }
}
