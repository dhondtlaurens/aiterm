import AppKit
import SwiftUI
import Testing
@testable import AiTermCore
@testable import AiTerm

/// A selection made away from the list — Focus View, a notification bringing an iTerm2 window
/// forward — scrolls the sidebar to its row, which could otherwise sit below the fold.
@MainActor
struct SidebarScrollTests {
    /// The last project starts collapsed and opens in the same turn its row is selected, as Focus
    /// View does it: the row is scrolled to once the table has it.
    @Test func aSelectionMadeElsewhereScrollsItsRowIntoView() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = AppController(store: StateStore(url: dir.appendingPathComponent("state.json")), preferences: .scratch())
        try controller.loadWorkspace()
        for index in 0..<20 {
            let project = Project(id: UUID(), name: "Repo \(index)", path: "/repo\(index)", provider: .git, remoteUrl: nil,
                                  addedAt: Date(), collapsed: index == 19)
            controller.state.append(project: project)
            controller.state.terminals.append(TerminalItem(id: UUID(), projectId: project.id, name: "Shell", windowId: nil, createdAt: Date()))
        }

        let host = NSHostingView(rootView: SidebarView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        func table(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        let list = try #require(table(in: host))
        let last = try #require(controller.state.terminals.last)
        controller.state.updateProject(id: last.projectId) { $0.collapsed = false }
        controller.focus.browse(.terminal(last.id))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        // The last terminal is the last row. Not `selectedRow`: a selection set from the model
        // reaches the table's own `selectedRow` only later, if at all.
        #expect(list.numberOfRows == 41)
        #expect(list.visibleRect.contains(list.rect(ofRow: list.numberOfRows - 1)))
    }
}
