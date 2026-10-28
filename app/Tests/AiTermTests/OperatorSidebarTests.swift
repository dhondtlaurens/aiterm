import AppKit
import SwiftUI
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The list with the Operator in it: the OPERATOR heading first, always, as its "+" is the only way to
/// start a broadcast; while one exists the heading carries it, the "+" gone, and its section and the projects fold
/// into each other, one open at a time; then PROJECTS.
@MainActor
struct OperatorSidebarTests {
    private func hosted(_ controller: AppController) -> (NSHostingView<SidebarView>, NSWindow) {
        let (host, window) = HostedSidebar.make(controller, size: CGSize(width: 340, height: 500))
        return (host, window)
    }

    @Test func theListLeadsWithTheOperatorHeadingAndItsBroadcast() throws {
        let controller = AppController(preferences: .scratch())
        try controller.loadWorkspace()
        let (host, window) = hosted(controller)
        defer { window.orderOut(nil) }
        settle(host) { host.firstDescendant(NSTableView.self).map { $0.numberOfRows > 0 } ?? false }
        let list = try #require(host.firstDescendant(NSTableView.self))
        // OPERATOR, PROJECTS, the empty block.
        #expect(list.numberOfRows == 3)
        #expect(OperatorHeading.offersNewBroadcast(controller.rows.broadcast))

        let run = OperatorUIFixtures.run()
        controller.workspace.mutate { $0.runs = [run] }
        // OPERATOR, the broadcast's lead row, PROJECTS folded: no empty block.
        settle(host, describing: "the broadcast's group") { list.numberOfRows == 3 && controller.rows.projectsFolded }
        #expect(!OperatorHeading.offersNewBroadcast(controller.rows.broadcast), "one broadcast at a time: the \"+\" goes")
        #expect(controller.rows.broadcast?.operatorRow.title == run.name, "the lead row is the broadcast")

        // Folded, the Operator's section gives way to the projects: OPERATOR, PROJECTS, the empty block.
        controller.toggleFolded(run: run.id)
        settle(host, describing: "the projects open") { list.numberOfRows == 3 && !controller.rows.projectsFolded }
        controller.toggleFolded(run: run.id)
        settle(host, describing: "the Operator open again") { list.numberOfRows == 3 && controller.rows.projectsFolded }

        controller.workspace.mutate { $0.runs[0].state = .stopped }
        settle(host, describing: "the group gone with the broadcast") { list.numberOfRows == 3 }
        #expect(OperatorHeading.offersNewBroadcast(controller.rows.broadcast), "and the \"+\" returns")
    }

    @Test func theRowIsReadOutAsItIsDrawn() throws {
        let web = OperatorUIFixtures.project("pluto-web"), cms = OperatorUIFixtures.project("pluto-cms")
        var run = OperatorUIFixtures.run(name: "Checkout redesign", questions: [OperatorUIFixtures.question("retry policy?")],
                                         projectIds: [web.id, cms.id])
        run.firstPlanSize = 0
        var state = AppState()
        state.append(project: web); state.append(project: cms); state.runs = [run]
        let section = try #require(SidebarModel.broadcastSection(state: state, sessions: []))
        #expect(OperatorHeading.spoken(section) == "Checkout redesign, 0 of 0, pluto-web and pluto-cms, The Operator asks: retry policy?")
        #expect(OperatorHeading.help(section.header) == "pluto-web and pluto-cms\nThe Operator asks: retry policy?")
        #expect(OperatorRowView.label(section.operatorRow) == "Checkout redesign, the Operator’s Claude Code session")

        // Folded, it says so, and what needs you, once.
        state.setFolded(run: run.id, true)
        let folded = try #require(SidebarModel.broadcastSection(state: state, sessions: []))
        #expect(OperatorHeading.spoken(folded)
                == "Checkout redesign, 0 of 0, pluto-web and pluto-cms, The Operator asks: retry policy?, folded, 1 needs input")
    }

    /// VoiceOver offers the broadcast's menu as the OPERATOR heading's actions beside the fold, as a task's and a terminal's row do:
    /// Open Board first, the items' titles without the menu's ellipsis, and over a locked workspace, where the
    /// menu greys the rest, Open Board alone, which changes nothing.
    @Test func theHeadersMenuIsItsAccessibilityActions() throws {
        var run = OperatorUIFixtures.run()
        func actions(_ run: OperatorRun, locked: Bool = false) throws -> [String] {
            var state = AppState()
            state.runs = [run]
            let row = try #require(SidebarModel.broadcastRow(state: state))
            return OperatorHeading.voiceOverActions(row, canChangeWorkspace: !locked).map(\.actionTitle)
        }
        #expect(try actions(run) == ["Open Board", "Rename", "Pause Broadcast", "End Broadcast"])
        run.state = .paused
        #expect(try actions(run) == ["Open Board", "Rename", "Resume Broadcast", "End Broadcast"])
        run.state = .complete
        #expect(try actions(run) == ["Open Board", "Rename", "End Broadcast"])
        #expect(try actions(run, locked: true) == ["Open Board"])
    }
}
