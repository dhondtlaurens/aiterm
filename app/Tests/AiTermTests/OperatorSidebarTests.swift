import AppKit
import SwiftUI
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The list with the Operator in it: the OPERATOR heading first, always, as its "+" is the only way to
/// start a broadcast; the broadcast's header and the Operator's row under it while one exists, the "+" gone;
/// then PROJECTS.
@MainActor
struct OperatorSidebarTests {
    private func hosted(_ controller: AppController) -> (NSHostingView<SidebarView>, NSWindow) {
        let host = NSHostingView(rootView: SidebarView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 500)
        let window = testWindow(contentRect: host.frame, styleMask: [.titled])
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
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
        // OPERATOR, Newsletter signup, the Operator, PROJECTS, the empty block.
        settle(host, describing: "the broadcast's group") { list.numberOfRows == 5 }
        #expect(!OperatorHeading.offersNewBroadcast(controller.rows.broadcast), "one broadcast at a time: the \"+\" goes")

        // Folded, the header alone.
        controller.toggleFolded(run: run.id)
        settle(host, describing: "the group folded") { list.numberOfRows == 4 }
        controller.toggleFolded(run: run.id)
        settle(host, describing: "the group open") { list.numberOfRows == 5 }

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
        #expect(BroadcastHeaderRow.label(section.header) == "Broadcast Checkout redesign")
        #expect(BroadcastHeaderRow.spoken(section) == "0 of 0, pluto-web and pluto-cms, The Operator asks: retry policy?")
        #expect(BroadcastHeaderRow.help(section.header) == "pluto-web and pluto-cms\nThe Operator asks: retry policy?")
        #expect(OperatorRowView.label == "Operator, Claude Code session")

        // Folded, it says what needs you, once.
        state.setFolded(run: run.id, true)
        let folded = try #require(SidebarModel.broadcastSection(state: state, sessions: []))
        #expect(BroadcastHeaderRow.spoken(folded) == "0 of 0, pluto-web and pluto-cms, The Operator asks: retry policy?, 1 needs input")
    }

    /// VoiceOver offers the header's menu as its actions beside the fold, as a task's and a terminal's row do:
    /// Open Board first, the items' titles without the menu's ellipsis, and over a locked workspace, where the
    /// menu greys the rest, Open Board alone, which changes nothing.
    @Test func theHeadersMenuIsItsAccessibilityActions() throws {
        var run = OperatorUIFixtures.run()
        func actions(_ run: OperatorRun, locked: Bool = false) throws -> [String] {
            var state = AppState()
            state.runs = [run]
            let row = try #require(SidebarModel.broadcastRow(state: state))
            return BroadcastHeaderRow.voiceOverActions(row, canChangeWorkspace: !locked).map(\.actionTitle)
        }
        #expect(try actions(run) == ["Open Board", "Rename", "Pause Broadcast", "End Broadcast"])
        run.state = .paused
        #expect(try actions(run) == ["Open Board", "Rename", "Resume Broadcast", "End Broadcast"])
        run.state = .complete
        #expect(try actions(run) == ["Open Board", "Rename", "End Broadcast"])
        #expect(try actions(run, locked: true) == ["Open Board"])
    }
}
