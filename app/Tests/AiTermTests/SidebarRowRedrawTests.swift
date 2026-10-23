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
        let host = testHost(SidebarView(controller: controller).environment(\.rowBodyCounter, counter), size: CGSize(width: 340, height: 700))
        let window = testWindow(hosting: host, styleMask: [.titled])
        // OPERATORS, header, two project rows, two terminals and seven tasks.
        settle(host) { host.firstDescendant(NSTableView.self).map { $0.numberOfRows == 13 } ?? false }
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

    /// A change to the broadcast redraws its group's rows alone, and of those only what draws it: the Operator's
    /// own question changes its row and the header's line; its progress showing, the header alone; a change
    /// neither draws anything of, a decision recorded, redraws nothing.
    @Test func aBroadcastChangeRedrawsOnlyItsRows() throws {
        let sidebar = try hostedSidebar()
        defer { sidebar.window.orderOut(nil) }
        let run = OperatorUIFixtures.run(windowId: nil), operatorRow = OperatorRow.id(of: run.id)
        sidebar.controller.workspace.mutate { $0.runs = [run] }
        // The header and the Operator's row.
        sidebar.settleRows { sidebar.list.numberOfRows == 15 && sidebar.counter.counts[operatorRow] != nil }

        sidebar.counter.reset()
        sidebar.controller.workspace.mutate { $0.runs[0].questions = [OperatorUIFixtures.question("retry policy?")] }
        sidebar.settleRows { sidebar.counter.counts[operatorRow] != nil }
        #expect(sidebar.controller.rows.broadcast?.operatorRow.status == .needsInput)
        #expect(Set(sidebar.counter.counts.keys) == [run.id, operatorRow], "a request: redrawn \(sidebar.counter.counts.count) rows")

        sidebar.counter.reset()
        sidebar.controller.workspace.mutate { $0.runs[0].firstPlanSize = 4 }
        sidebar.settleRows { sidebar.counter.counts[run.id] != nil }
        #expect(sidebar.controller.rows.broadcast?.header.progress == "0 of 0")
        #expect(Set(sidebar.counter.counts.keys) == [run.id], "progress: redrawn \(sidebar.counter.counts.count) rows")

        sidebar.counter.reset()
        sidebar.controller.workspace.mutate { state in
            state.runs[0].decisions = [OperatorDecision(key: "k", text: "Kept the subtitle.", task: nil, at: Date(), challenge: nil)]
        }
        sidebar.settleRows()
        #expect(sidebar.counter.counts.isEmpty, "nothing the row draws: redrawn \(sidebar.counter.counts.count) rows")
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

    /// A driven task the Operator acts on decodes its words in their own view: its row's body is not run
    /// again frame by frame while its words decode.
    @Test func anActingRowIsNotRedrawnPerFrame() throws {
        let sidebar = try hostedSidebar()
        defer { sidebar.window.orderOut(nil) }
        let acted = sidebar.tasks[2]
        let run = OperatorUIFixtures.run(projectIds: [sidebar.project.id])
        sidebar.controller.rows.actingSource = { OperatorActs(tasks: [acted.id: .answering]) }
        sidebar.controller.workspace.mutate { state in
            state.runs = [run]
            if let i = state.tasks.firstIndex(where: { $0.id == acted.id }) {
                state.tasks[i].operated = OperatorUIFixtures.operated(run: run.id, key: "t2", state: .working)
            }
        }
        sidebar.settleRows { sidebar.host.firstDescendant(DecodeWordsView.self) != nil }
        #expect(sidebar.host.firstDescendant(DecodeWordsView.self) != nil, "the acting row decodes")
        sidebar.counter.reset()
        settle(sidebar.host, for: 0.5)
        #expect(sidebar.counter.counts[acted.id] == nil, "the acting row was redrawn \(sidebar.counter.counts[acted.id] ?? 0) times in 0.5 s")
    }
}
