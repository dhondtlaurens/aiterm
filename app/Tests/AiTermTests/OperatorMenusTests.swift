import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The operator items of the sidebar's menus, in the picked design's words and order: OPERATORS' "+",
/// the Operator's "+" and its menu, an operation's menu and a driven task's.
struct OperatorMenusTests {
    private func titles(_ items: [OperatorMenuItem]) -> [String] { items.map { $0 == .separator ? "—" : $0.title } }

    @Test func theOperatorsMenusSayWhatTheDesignSays() {
        #expect(titles(OperatorMenus.operatorsGroup) == ["New Operation…"])
        #expect(titles(OperatorMenus.headerPlus) == ["New Operation…"])
        #expect(titles(OperatorMenus.header) == ["New Operation…"], "no persona to edit, duplicate or trash")
        #expect(OperatorMenus.header.filter(\.isDestructive).isEmpty)
    }

    @Test func anOperationsMenuOffersWhatItsStateAllows() {
        #expect(titles(OperatorMenus.operation(.active))
                == ["Overview…", "Rename…", "—", "Pause", "Interrupt Agents", "—", "End Operation…"])
        #expect(titles(OperatorMenus.operation(.planning))
                == ["Overview…", "Rename…", "—", "Pause", "Interrupt Agents", "—", "End Operation…"])
        #expect(titles(OperatorMenus.operation(.paused))
                == ["Overview…", "Rename…", "—", "Resume", "Interrupt Agents", "—", "End Operation…"],
                "paused, its agents finish their turn: Interrupt Agents stops them now")
        #expect(titles(OperatorMenus.operation(.operatorOffline))
                == ["Overview…", "Rename…", "—", "Resume", "Interrupt Agents", "—", "End Operation…"])
        #expect(titles(OperatorMenus.operation(.complete)) == ["Overview…", "Rename…", "—", "End Operation…"])
        #expect(OperatorMenus.operation(.active).filter(\.isDestructive) == [.endOperation])
    }

    @Test func aDrivenTaskCanBeTakenOverHandedBackAndStopped() {
        let run = UUID()
        #expect(OperatorMenus.task(nil).isEmpty, "a task you made yourself")
        #expect(titles(OperatorMenus.task(OperatorUIFixtures.operated(run: run, key: "a", state: .working)))
                == ["Take Over", "—", "Stop Task…"])
        #expect(titles(OperatorMenus.task(OperatorUIFixtures.operated(run: run, key: "a", state: .working, takenOver: true)))
                == ["Hand Back", "—", "Stop Task…"], "taken over, it is still the operator's to stop")
        #expect(titles(OperatorMenus.task(OperatorUIFixtures.operated(run: run, key: "a", state: .blocked)))
                == ["Take Over", "—", "Stop Task…"])
        #expect(titles(OperatorMenus.task(OperatorUIFixtures.operated(run: run, key: "a", state: .failed)))
                == ["Take Over", "—", "Stop Task…"], "failed is still open")
        for ended in [OperatedState.accepted, .noChange, .published, .stopped] {
            #expect(titles(OperatorMenus.task(OperatorUIFixtures.operated(run: run, key: "a", state: ended, sha: "4f2a91c")))
                    == ["Take Over"], "\(ended): ended, there is nothing left to stop")
            #expect(titles(OperatorMenus.task(OperatorUIFixtures.operated(run: run, key: "a", state: ended, takenOver: true)))
                    == ["Hand Back"], "\(ended), taken over: ownership is never stranded with you")
        }
        #expect(OperatorMenus.task(OperatorUIFixtures.operated(run: run, key: "a", state: .working)).filter(\.isDestructive)
                == [.stopTask])
    }

    /// Stop Task… asks first, as End Operation… does: ⎋ is Cancel and changes nothing; Stop Task ends the
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
        #expect(alert.detail == "Its operator stops on it for good, and the tasks that build on it wait for you. Its window and its branch stay; an agent at work there finishes its turn.")
        #expect(alert.buttons == ["Stop Task", "Cancel"] && alert.escapeButton == 1 && !alert.defaultDeletes)

        #expect(await !controller.confirmStop(task))
        #expect(controller.state.task(id: task.id)?.operated?.state == .working, "cancelled, nothing changes")
        #expect(await controller.confirmStop(task))
        #expect(prompter.asked == [alert, alert])
        await eventually(describing: "the task stopped") { controller.state.task(id: task.id)?.operated?.state == .stopped }
    }
}
