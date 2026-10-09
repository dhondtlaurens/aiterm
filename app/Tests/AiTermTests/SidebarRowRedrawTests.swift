import AppKit
import SwiftUI
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport
@testable import AiTerm

/// A row redraws for its own data, not for a change to another row's: each row reads whether it is
/// selected, its removal and its missing checkout for its own id alone. Counted in a hosted sidebar,
/// where SwiftUI decides what to re-run, rather than by tracking a body evaluated by hand.
@MainActor
@Suite(.serialized) struct SidebarRowRedrawTests {
    @MainActor private struct Sidebar {
        let controller: AppController
        let counter: RowBodyCounter
        let host: NSView
        let window: NSWindow
        let list: NSTableView
        let project: Project
        let tasks: [TaskItem]
        let terminals: [TerminalItem]

        /// Every row on screen, by id: two project headers, two terminals and seven tasks.
        var allRows: Set<UUID> {
            Set(controller.state.projects.map(\.id) + tasks.map(\.id) + terminals.map(\.id))
        }

        /// Turns the run loop until SwiftUI has drawn what the change asked for, then a little
        /// longer, so a row redrawn late is counted too.
        func settleRows(until condition: () -> Bool = { true }) {
            settle(host, until: condition)
            settle(host, for: 0.1)
        }
    }

    private func hostedSidebar() throws -> Sidebar {
        let controller = AppController(preferences: .scratch())
        try controller.loadWorkspace()
        let projects = ["Repo", "Other repo"].map { name in
            Project(id: UUID(), name: name, path: "/\(name)", provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        }
        let tasks = (0..<7).map { index in
            TaskItem(id: UUID(), projectId: projects[index < 4 ? 0 : 1].id, title: "Task \(index)", branch: "feat/\(index)",
                     worktreePath: "/wt\(index)", baseBranch: "main", jira: nil, agent: .claude, model: "sonnet",
                     reasoning: nil, firstPrompt: nil, appendTicket: false, createdAt: Date(), windowId: nil)
        }
        let terminals = (0..<2).map { index in
            TerminalItem(id: UUID(), projectId: projects[0].id, name: "Shell \(index)", windowId: nil, createdAt: Date())
        }
        controller.workspace.mutate { state in
            state.items = projects.map { .project($0) }
            state.tasks = tasks
            state.terminals = terminals
        }
        controller.focus.browse(.task(tasks[0].id))

        let counter = RowBodyCounter()
        let host = NSHostingView(rootView: SidebarView(controller: controller).environment(\.rowBodyCounter, counter))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        // Header, two project rows, two terminals and seven tasks.
        settle(host) { host.firstDescendant(NSTableView.self).map { $0.numberOfRows == 12 } ?? false }
        let list = try #require(host.firstDescendant(NSTableView.self))
        let sidebar = Sidebar(controller: controller, counter: counter, host: host, window: window, list: list,
                              project: projects[0], tasks: tasks, terminals: terminals)
        sidebar.settleRows()
        #expect(Set(counter.counts.keys) == sidebar.allRows, "every row is drawn once to begin with")
        return sidebar
    }

    @Test func anArrowKeyRedrawsOnlyTheRowItLeavesAndTheRowItReaches() throws {
        let sidebar = try hostedSidebar()
        defer { sidebar.window.orderOut(nil) }
        #expect(sidebar.window.makeFirstResponder(sidebar.list))
        sidebar.counter.reset()

        let arrow = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: sidebar.window.windowNumber, context: nil,
                                                 characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                                                 isARepeat: false, keyCode: 125))
        sidebar.list.keyDown(with: arrow)
        sidebar.settleRows { sidebar.counter.counts[sidebar.tasks[1].id] != nil }

        #expect(sidebar.controller.focus.selection == .task(sidebar.tasks[1].id))
        #expect(Set(sidebar.counter.counts.keys) == [sidebar.tasks[0].id, sidebar.tasks[1].id],
                "redrawn: \(sidebar.counter.counts.count) of \(sidebar.allRows.count) rows")
    }

    @Test func aRemovalRedrawsOnlyItsRow() throws {
        let sidebar = try hostedSidebar()
        defer { sidebar.window.orderOut(nil) }
        let removed = sidebar.tasks[2].id

        for removal: TaskRemoval? in [.removing, .closing, nil] {
            sidebar.counter.reset()
            sidebar.controller.seedSnapshotRemoval(removal, of: removed)
            sidebar.settleRows { sidebar.counter.counts[removed] != nil }
            #expect(Set(sidebar.counter.counts.keys) == [removed], "\(String(describing: removal)): redrawn \(sidebar.counter.counts.count) of \(sidebar.allRows.count) rows")
        }
    }

    @Test func aMissingCheckoutRedrawsOnlyItsRow() throws {
        let sidebar = try hostedSidebar()
        defer { sidebar.window.orderOut(nil) }
        let missing = sidebar.tasks[5].id

        for gone: Set<UUID> in [[missing], []] {
            sidebar.counter.reset()
            sidebar.controller.checkouts.seedSnapshotFixture(WorkspaceScan(branchByCwd: [:], projectBranch: [:],
                                                                            missingCheckouts: gone, removedTasks: [],
                                                                            remotes: [:]))
            sidebar.settleRows { sidebar.counter.counts[missing] != nil }
            #expect(Set(sidebar.counter.counts.keys) == [missing], "missing \(gone.count): redrawn \(sidebar.counter.counts.count) of \(sidebar.allRows.count) rows")
        }
    }

    @Test func aThreadCountRedrawsOnlyItsRow() throws {
        let sidebar = try hostedSidebar()
        defer { sidebar.window.orderOut(nil) }
        let counted = sidebar.tasks[3].id

        for threads: ReviewThreads? in [ReviewThreads(resolved: 2, total: 5), ReviewThreads(resolved: 3, total: 5), nil] {
            sidebar.counter.reset()
            sidebar.controller.reviewThreads.seedSnapshotThreads(threads, of: counted)
            sidebar.settleRows { sidebar.counter.counts[counted] != nil }
            #expect(Set(sidebar.counter.counts.keys) == [counted],
                    "\(String(describing: threads)): redrawn \(sidebar.counter.counts.count) of \(sidebar.allRows.count) rows")
        }
    }
}
