import AppKit
import SwiftUI
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The list with operators in it: OPERATORS first, always — its "+" is the only way to the first
/// operator — then each operator's header, its operations when it is open, and PROJECTS after.
@MainActor
struct OperatorSidebarTests {
    private func hosted(_ controller: AppController) -> (NSHostingView<SidebarView>, NSWindow) {
        let host = NSHostingView(rootView: SidebarView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        return (host, window)
    }

    @Test func theListLeadsWithTheOperatorsAndTheirOperations() throws {
        let controller = AppController(preferences: .scratch())
        try controller.loadWorkspace()
        let (host, window) = hosted(controller)
        defer { window.orderOut(nil) }
        settle(host) { host.firstDescendant(NSTableView.self).map { $0.numberOfRows > 0 } ?? false }
        let list = try #require(host.firstDescendant(NSTableView.self))
        // OPERATORS, PROJECTS, the empty block.
        #expect(list.numberOfRows == 3)

        controller.rows.operatorSource = { [OperatorUIFixtures.senior] }
        controller.workspace.mutate { $0.runs = [OperatorUIFixtures.run()] }
        // OPERATORS, Senior engineer, Newsletter signup, PROJECTS, the empty block.
        settle(host, describing: "the operation's row") { list.numberOfRows == 5 }

        controller.toggleCollapsed(operator: "senior")
        settle(host, describing: "the operator folded") { list.numberOfRows == 4 }
    }

    @Test func movingAnOperatorToTheTrashAsksFirst() async throws {
        let prompter = ScriptedPrompter(answering: "⎋")
        let controller = AppController(preferences: .scratch(), prompter: prompter)
        try controller.loadWorkspace()
        #expect(await !controller.confirmTrash(OperatorUIFixtures.senior))
        #expect(prompter.asked == [OperatorAlerts.moveToTrash(OperatorUIFixtures.senior)])
    }

    @Test func anOperationsCaptionSaysItsCountInWords() {
        var row = SidebarModel.operationRow(run: OperatorUIFixtures.run(), tasks: [])
        row.attention = 2
        #expect(OperationCaptionLine.spoken(row) == "0 of 0 done, 2 waiting on you")
        row.showsProgress = false; row.caption = "plan waits for you"
        #expect(OperationCaptionLine.spoken(row) == "plan waits for you")
    }
}
