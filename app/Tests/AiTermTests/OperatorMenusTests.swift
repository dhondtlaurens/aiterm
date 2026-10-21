import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The operator items of the sidebar's menus, in the picked design's words and order: the OPERATOR
/// heading's "+", the broadcast header's menu and a driven task's (spec §3, §9, §13).
struct OperatorMenusTests {
    private func titles(_ items: [OperatorMenuItem]) -> [String] { items.map { $0 == .separator ? "—" : $0.title } }

    @Test func theHeadingsPlusStartsABroadcast() {
        #expect(titles(OperatorMenus.headingPlus) == ["New Broadcast…"])
    }

    /// Open Board first, as the header's button; no Interrupt Agents: an agent always finishes its turn.
    @Test func theBroadcastsMenuOffersWhatItsStateAllows() {
        func menu(_ state: OperatorRunState, intent: OperatorRunState? = nil) -> [String] {
            var run = OperatorUIFixtures.run(state: state)
            run.intent = intent
            var workspace = AppState()
            workspace.runs = [run]
            return SidebarModel.broadcastRow(state: workspace).map { titles(OperatorMenus.broadcast($0)) } ?? []
        }
        #expect(menu(.active) == ["Open Board", "—", "Rename…", "—", "Pause Broadcast", "—", "End Broadcast…"])
        #expect(menu(.planning) == ["Open Board", "—", "Rename…", "—", "Pause Broadcast", "—", "End Broadcast…"])
        #expect(menu(.paused) == ["Open Board", "—", "Rename…", "—", "Resume Broadcast", "—", "End Broadcast…"])
        #expect(menu(.active, intent: .paused) == ["Open Board", "—", "Rename…", "—", "Resume Broadcast", "—", "End Broadcast…"])
        #expect(menu(.operatorOffline) == ["Open Board", "—", "Rename…", "—", "Resume Broadcast", "—", "End Broadcast…"])
        #expect(menu(.complete) == ["Open Board", "—", "Rename…", "—", "End Broadcast…"])
        var workspace = AppState()
        workspace.runs = [OperatorUIFixtures.run()]
        #expect(SidebarModel.broadcastRow(state: workspace).map { OperatorMenus.broadcast($0).filter(\.isDestructive) } == [],
                "End Broadcast… is not red: nothing is deleted, and it asks with a blue default")
    }

    @Test func aDrivenTaskCanBeTakenOverHandedBackAndStopped() {
        let run = OperatorUIFixtures.run()
        func menu(_ operated: OperatedTask?) -> [String] { titles(OperatorMenus.task(operated, broadcastLive: true)) }
        #expect(menu(nil).isEmpty, "a task you made yourself")
        #expect(menu(OperatorUIFixtures.operated(run: run.id, key: "a", state: .accepted)) == ["Take Over", "—", "Stop Task…"])
        #expect(menu(OperatorUIFixtures.operated(run: run.id, key: "a", state: .working)) == ["Take Over", "—", "Stop Task…"])
        #expect(menu(OperatorUIFixtures.operated(run: run.id, key: "a", state: .working, takenOver: true))
                == ["Hand Back", "—", "Stop Task…"], "taken over, it is still the Operator's to stop")
        #expect(menu(OperatorUIFixtures.operated(run: run.id, key: "a", state: .blocked)) == ["Take Over", "—", "Stop Task…"])
        #expect(menu(OperatorUIFixtures.operated(run: run.id, key: "a", state: .failed)) == ["Take Over", "—", "Stop Task…"],
                "failed is still open")
        for ended in [OperatedState.noChange, .published, .stopped] {
            #expect(menu(OperatorUIFixtures.operated(run: run.id, key: "a", state: ended, sha: "4f2a91c")) == ["Take Over"],
                    "\(ended): ended, there is nothing left to stop")
            #expect(menu(OperatorUIFixtures.operated(run: run.id, key: "a", state: ended, takenOver: true)) == ["Hand Back"],
                    "\(ended), taken over: ownership is never stranded with you")
        }
        #expect(OperatorMenus.task(OperatorUIFixtures.operated(run: run.id, key: "a", state: .working), broadcastLive: true)
                    .filter(\.isDestructive) == [.stopTask])
    }

    /// An ended broadcast handed its tasks to you: there is no one to hand one back to, nor anything of the
    /// Operator's to take over or stop. Its row says whether its broadcast is live.
    @Test func aTaskOfAnEndedBroadcastHasNoOperatorItems() throws {
        var run = OperatorUIFixtures.run()
        let project = OperatorUIFixtures.project("pluto-web")
        let task = OperatorUIFixtures.task("Schema", project: project.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "a", state: .working, takenOver: true))
        func row(_ run: OperatorRun?) throws -> TaskRow {
            var state = AppState()
            state.append(project: project); state.tasks = [task]; state.runs = run.map { [$0] } ?? []
            // Under the broadcast while it lives, back in its project once it has ended.
            return try #require(SidebarModel.broadcastSection(state: state, sessions: [])?.tasks.first
                                ?? SidebarModel.sections(state: state, sessions: [], branchByCwd: [:], projectBranch: [:]).first?.tasks.first)
        }
        #expect(try row(run).broadcastLive)
        #expect(titles(OperatorMenus.task(task.operated, broadcastLive: try row(run).broadcastLive)) == ["Hand Back", "—", "Stop Task…"])
        run.intent = .stopped
        #expect(try !row(run).broadcastLive, "being ended")
        run.state = .stopped
        #expect(try !row(run).broadcastLive, "ended")
        #expect(try !row(nil).broadcastLive, "its broadcast gone")
        #expect(OperatorMenus.task(task.operated, broadcastLive: false).isEmpty)
    }

    /// Stop Task… asks first, as End Broadcast… does: ⎋ is Cancel and changes nothing; Stop Task ends the
    /// task `stopped` for its operator.
    @MainActor @Test func stoppingATaskAsksFirst() async throws {
        let prompter = ScriptedPrompter(answering: "⎋", "↩")
        let controller = AppController(preferences: .scratch(), prompter: prompter)
        try controller.loadWorkspace()
        let run = OperatorUIFixtures.run()
        let project = OperatorUIFixtures.project("pluto-cms")
        let task = OperatorUIFixtures.task("The signup block schema", project: project.id,
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "a", state: .working))
        controller.workspace.mutate { state in state.runs = [run]; state.append(project: project); state.tasks.append(task) }

        let alert = OperatorAlerts.stopTask(task)
        #expect(alert.message == "Stop “The signup block schema”?")
        #expect(alert.detail == "The Operator stops on it for good, and the tasks that build on it wait for you. Its window and its branch stay; an agent at work there finishes its turn.")
        #expect(alert.buttons == ["Stop Task", "Cancel"] && alert.escapeButton == 1 && !alert.defaultDeletes)

        #expect(await !controller.confirmStop(task))
        #expect(controller.state.task(id: task.id)?.operated?.state == .working, "cancelled, nothing changes")
        #expect(await controller.confirmStop(task))
        #expect(prompter.asked == [alert, alert])
        await eventually(describing: "the task stopped") { controller.state.task(id: task.id)?.operated?.state == .stopped }
    }
}

extension OperatorMenusTests {
    @Test func anAcceptedUnpublishedTaskHasAStopEscapeHatch() {
        let run = OperatorUIFixtures.run()
        var operated = OperatorUIFixtures.operated(run: run.id, key: "a", state: .accepted, end: .merge, sha: "4f2a91c")
        #expect(OperatorMenus.task(operated, broadcastLive: true).contains(.stopTask))
        operated.publication = TaskPublication(leftForYou: true)
        #expect(!OperatorMenus.task(operated, broadcastLive: true).contains(.stopTask))
    }
}
