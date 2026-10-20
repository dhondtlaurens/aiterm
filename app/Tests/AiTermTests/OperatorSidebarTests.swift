import AppKit
import SwiftUI
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The list with the Operator in it: the OPERATOR heading first, always, as its "+" is the only way to
/// start a broadcast; the broadcast row under it while one exists, the "+" gone; then PROJECTS.
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
        // OPERATOR, Newsletter signup, PROJECTS, the empty block.
        settle(host, describing: "the broadcast's row") { list.numberOfRows == 4 }
        #expect(!OperatorHeading.offersNewBroadcast(controller.rows.broadcast), "one broadcast at a time: the \"+\" goes")

        controller.workspace.mutate { $0.runs[0].state = .stopped }
        settle(host, describing: "the row gone with the broadcast") { list.numberOfRows == 3 }
        #expect(OperatorHeading.offersNewBroadcast(controller.rows.broadcast), "and the \"+\" returns")
    }

    @Test func theRowIsReadOutAsItIsDrawn() throws {
        let web = OperatorUIFixtures.project("pluto-web"), cms = OperatorUIFixtures.project("pluto-cms")
        var run = OperatorUIFixtures.run(name: "Checkout redesign", questions: [OperatorUIFixtures.question("retry policy?")],
                                         projectIds: [web.id, cms.id])
        run.firstPlanSize = 0
        var state = AppState()
        state.append(project: web); state.append(project: cms); state.runs = [run]
        let row = try #require(SidebarModel.broadcastRow(state: state))
        #expect(BroadcastRowView.label(row) == "Broadcast Checkout redesign")
        #expect(BroadcastRowView.spoken(row) == "0 of 0 done, pluto-web and pluto-cms, The Operator asks: retry policy?")
    }
}
