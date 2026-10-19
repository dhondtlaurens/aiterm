import AppKit
import SwiftUI
import Testing
import AiTermUI
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The overview's footer at each moment, its questions, and the sheet slot it opens in (spec §10.7).
@MainActor
struct OperationOverviewSheetTests {
    @Test func theFooterOffersWhatTheMomentAllows() {
        func titles(_ footer: OperationOverview.Footer) -> ([String], String?) {
            let buttons = OverviewFooterButtons(footer)
            return (buttons.leading.map(\.title), buttons.primary?.title)
        }
        #expect(titles(.planWaits) == (["End Operation…"], "Approve Plan"))
        #expect(titles(.working) == (["Pause", "End Operation…"], nil))
        #expect(titles(.paused) == (["Resume", "End Operation…"], nil))
        #expect(titles(.done) == (["Give It More"], "End Operation"))
        #expect(OperationOverview.Link.openTask(UUID()).title == "Open Task")
        #expect(OperationOverview.Link.answerInWindow.title == "Answer in Window")
    }

    @Test func endingAsksFirstWithCancelOnEscape() {
        let end = OperatorAlerts.endOperation(OperatorUIFixtures.run())
        #expect(end.message == "End “Newsletter signup”?")
        #expect(end.detail == "The operator stops for good and its window closes. Its tasks stay as they are, now just yours.")
        #expect(end.buttons == ["End Operation", "Cancel"] && end.escapeButton == 1 && !end.defaultDeletes)
    }

    @Test func cancellingEndLeavesTheOperationRunning() async throws {
        let prompter = ScriptedPrompter(answering: "⎋")
        let controller = AppController(preferences: .scratch(), prompter: prompter)
        try controller.loadWorkspace()
        let run = OperatorUIFixtures.run()
        controller.workspace.mutate { $0.runs = [run] }
        #expect(await !controller.confirmEnd(run))
        #expect(prompter.asked == [OperatorAlerts.endOperation(run)])
        #expect(controller.state.runs.first?.state == .active)
    }

    @Test func theOverviewOpensInTheSheetSlotForALiveOperationOnly() throws {
        let controller = AppController(preferences: .scratch())
        try controller.loadWorkspace()
        let run = OperatorUIFixtures.run()
        controller.presentOverview(run: run.id)
        #expect(controller.sheet == nil, "no such operation")
        controller.workspace.mutate { $0.runs = [run] }
        controller.presentOverview(run: run.id)
        guard case .operationOverview(let id) = controller.sheet else { Issue.record("no overview"); return }
        #expect(id == run.id)
    }

    /// A notification's click on a waiting plan or a finished operation (spec §10.3, §10.8): D7 records
    /// the overview it asks for on the operator controller; the app presents it, once, and clears it.
    @Test func aNotificationsClickOpensTheOverview() async throws {
        let controller = AppController(preferences: .scratch())
        try controller.loadWorkspace()
        let run = OperatorUIFixtures.run(state: .complete)
        controller.workspace.mutate { $0.runs = [run] }
        controller.openNote(.overview(run.id))
        await eventually(describing: "the overview in the sheet slot") {
            if case .operationOverview(run.id) = controller.sheet { true } else { false }
        }
        #expect(controller.operatorController.presentOverview == nil, "presented once, then cleared")
    }

    /// A request already there when the app starts watching — a click that launched it — is presented too.
    @Test func aRequestMadeBeforeTheWatchIsPresented() throws {
        let controller = AppController(preferences: .scratch())
        try controller.loadWorkspace()
        let run = OperatorUIFixtures.run()
        controller.workspace.mutate { $0.runs = [run] }
        controller.operatorController.presentOverview = run.id
        controller.presentRequestedOverview()
        guard case .operationOverview(let id) = controller.sheet else { Issue.record("no overview"); return }
        #expect(id == run.id)
        #expect(controller.operatorController.presentOverview == nil)
    }

    /// Rename… is the `NameSheet` every other rename is, with the operation's own copy.
    @Test func renamingAnOperationOpensTheNameSheet() throws {
        let controller = AppController(preferences: .scratch())
        try controller.loadWorkspace()
        let run = OperatorUIFixtures.run()
        controller.workspace.mutate { $0.runs = [run] }
        controller.perform(.rename, on: run)
        guard case .rename(let target) = controller.sheet else { Issue.record("no rename sheet"); return }
        #expect(target == .operation(run))
        #expect(target.title == "Rename operation" && target.fieldLabel == "Operation name" && target.name == "Newsletter signup")
        #expect(target.subtitle == "Renames its row and its overview; its operator’s window and its tasks keep theirs.")
    }

    @Test func theSheetIsASheetsWidth() {
        let overview = OperationOverview.make(run: OperatorUIFixtures.run(), state: AppState())
        let host = NSHostingView(rootView: OperationOverviewSheet(overview: overview, actions: OverviewActions()))
        #expect(host.fittingSize.width == Sheet.width)
    }

    /// Approve Plan carries the revision the sheet showed — never "the latest": a plan revised while the
    /// sheet is open needs its own approval (Review Focus: a stale approval releases nothing).
    @Test func approvePlanSendsTheRevisionTheSheetShowed() {
        var sent: [Int] = [], moments: [String] = []
        let actions = OverviewActions(approvePlan: { sent.append($0) }, pause: { moments.append("pause") },
                                      resume: { moments.append("resume") }, end: { moments.append($0 ? "end…" : "end") },
                                      giveItMore: { moments.append("more") })
        let run = OperatorUIFixtures.run(state: .planning, planRevision: 3, approvedRevision: 1)
        var state = AppState()
        let task = OperatorUIFixtures.task("Schema", jira: "PLUTO-1", project: UUID(),
                                           operated: OperatorUIFixtures.operated(run: run.id, key: "k", state: .planned))
        state.tasks = [task]; state.runs = [run]
        let shown = OperationOverview.make(run: run, state: state)
        #expect(shown.plan?.revision == 3)
        // The operator submits revision 4 after the sheet drew; the click still sends 3.
        var revised = run; revised.planRevision = 4
        state.runs = [revised]
        OverviewButton.approvePlan.perform(shown, actions)
        #expect(sent == [3])
        #expect(OperationOverview.make(run: revised, state: state).plan?.revision == 4)
        for button: OverviewButton in [.pause, .resume, .endConfirm, .end, .giveItMore] { button.perform(shown, actions) }
        #expect(moments == ["pause", "resume", "end…", "end", "more"])
    }

    /// What D refuses reaches the banner, named after what it was for, and is never dropped.
    @Test func whatTheOperatorControllerRefusesLandsInTheBanner() async throws {
        let controller = AppController(preferences: .scratch())
        try controller.loadWorkspace()
        let run = OperatorUIFixtures.run()
        controller.rename(run: run, to: "Other")
        await eventually(describing: "the rename's banner") { controller.notices.issue != nil }
        #expect(controller.notices.issue?.title == "Couldn’t rename “Newsletter signup”.")
        #expect(controller.notices.issue?.reason == "This operation is no longer in AiTerm.")
        controller.notices.dismissIssue()
        controller.approvePlan(run, revision: 1)
        await eventually(describing: "the approval's banner") { controller.notices.issue != nil }
        #expect(controller.notices.issue?.title == "Couldn’t approve the plan of “Newsletter signup”.")
    }
}
