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

        /// Every row on screen, by id: two project headers, two terminals and seven tasks. No signal is
        /// configured, so the Operator's row is left out.
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
        try controller.workspace.load()
        let projects = ["Repo", "Other repo"].map { name in
            Project.make(name: name, path: "/\(name)", addedAt: Date())
        }
        let tasks = (0..<7).map { index in
            TaskItem.make(project: projects[index < 4 ? 0 : 1].id, title: "Task \(index)", branch: "feat/\(index)",
                          worktreePath: "/wt\(index)", model: "sonnet", createdAt: Date())
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
        let host = testHost(SidebarView(controller: controller).environment(\.rowBodyCounter, counter), size: CGSize(width: 340, height: 760))
        let window = testWindow(hosting: host, styleMask: [.titled])
        // OPERATOR heading, header, two project rows, two terminals and seven tasks.
        settle(host) { host.firstDescendant(NSTableView.self).map { $0.numberOfRows == 13 } ?? false }
        let list = try #require(host.firstDescendant(NSTableView.self))
        let sidebar = Sidebar(controller: controller, counter: counter, host: host, window: window, list: list,
                              project: projects[0], tasks: tasks, terminals: terminals)
        sidebar.settleRows()
        #expect(Set(counter.counts.keys) == sidebar.allRows, "every row is drawn once to begin with")
        return sidebar
    }

    @Test func expandedSignalHeadersIgnoreLedgersAndTheirChildStatusChanges() throws {
        let sidebar = try hostedSidebar(); defer { sidebar.window.orderOut(nil) }
        let signal = Signal(name: "Tickets", createdAt: Date(), source: .jira(JiraConditions()), work: SignalWork(prompt: "Work"),
            agents: [.init(agent: .claude, model: "opus", reasoning: nil)], finish: SignalFinish(doneWhen: .operatorJudges, then: .keep))
        var record = SignalTask(signal: signal.id, item: .ticket(site: "https://jira.example", key: "PAY-1"), startedAt: Date())
        record.phase = .working; record.configuration = signal
        sidebar.controller.workspace.mutate { state in
            state.signals = [signal]; state.operatorSession = OperatorSession(createdAt: Date())
            state.tasks[0].signalTask = record; state.operatorOpen = true
        }
        sidebar.settleRows(); sidebar.counter.reset()
        sidebar.controller.workspace.mutate { $0.operatorSession?.remember(key: "result", result: "ok", at: Date()) }
        sidebar.settleRows()
        #expect(sidebar.counter.counts.isEmpty, "A ledger entry is not a header or row change.")
        sidebar.counter.reset()
        let tab = OperatorServiceFixtures.session("worker", tag: sidebar.tasks[0].id, state: .needsInput)
        sidebar.controller.live.handle(.sessionOpened(tab))
        sidebar.settleRows { sidebar.counter.counts[sidebar.tasks[0].id] != nil }
        #expect(sidebar.counter.counts[signal.id] == nil, "An expanded heading has no status counts to redraw.")
    }
    @Test func anArrowKeyRedrawsOnlyTheRowItLeavesAndTheRowItReaches() throws {
        let sidebar = try hostedSidebar()
        defer { sidebar.window.orderOut(nil) }
        #expect(sidebar.window.makeFirstResponder(sidebar.list))
        sidebar.settleRows()
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
            sidebar.controller.remover.seedSnapshotRemoval(removal, of: removed)
            sidebar.settleRows { sidebar.counter.counts[removed] != nil }
            #expect(Set(sidebar.counter.counts.keys) == [removed], "\(String(describing: removal)): redrawn \(sidebar.counter.counts.count) of \(sidebar.allRows.count) rows")
        }
    }

    /// An Operator question redraws the Operator's row; a decision that changes no visible value redraws nothing.
    @Test func aSessionQuestionRedrawsOnlyTheOperatorAndBookkeepingRedrawsNothing() throws {
        let sidebar = try hostedSidebar()
        defer { sidebar.window.orderOut(nil) }
        let operatorRow = OperatorRow.id(of: OperatorSession.rowID)
        sidebar.controller.workspace.mutate { $0.operatorSession = OperatorSession(createdAt: Date()); $0.operatorOpen = true }
        sidebar.settleRows()
        sidebar.counter.reset()
        sidebar.controller.workspace.mutate { $0.operatorSession?.questions = [
            OperatorSession.Question(id: "question", task: nil, text: "Which locale?", openedAt: Date())
        ] }
        sidebar.settleRows { sidebar.counter.counts[operatorRow] != nil }
        #expect(sidebar.controller.rows.signalOperator.status == .needsInput)
        #expect(Set(sidebar.counter.counts.keys) == [operatorRow], "the question brings the Operator's row in, and only it draws")
        sidebar.counter.reset()
        sidebar.controller.workspace.mutate { $0.operatorSession?.remember(key: "note", result: ["status": "recorded"], at: Date()) }
        sidebar.settleRows()
        #expect(sidebar.counter.counts.isEmpty, "A saved tool result changes no drawn row")
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

    /// Baseline 1, final 0: a status the expanded header does not draw.
    @Test func anExpandedProjectHeaderDoesNotRedrawForItsTasksStatus() throws {
        let sidebar = try hostedSidebar()
        defer { sidebar.window.orderOut(nil); sidebar.controller.shutdown() }
        let session = SessionInfo.make("header-worker", task: sidebar.tasks[0].id)
        sidebar.controller.live.sessions = [session]
        sidebar.settleRows()
        sidebar.counter.reset()
        var changed = session; changed.state = .working
        sidebar.controller.live.sessions = [changed]
        sidebar.settleRows { sidebar.counter.counts[sidebar.tasks[0].id] != nil }
        print("Project header status redraws: \(sidebar.counter.counts[sidebar.project.id] ?? 0)")
        #expect(sidebar.counter.counts[sidebar.project.id] ?? 0 == 0, "baseline 1; final 0")
    }

    /// A taken-over worker's status changes its row, leaving the heading's words and attention unchanged.
    @Test func theSectionHeadingsDoNotRedrawForAStatusTheyDoNotDraw() throws {
        let sidebar = try hostedSidebar()
        defer { sidebar.window.orderOut(nil); sidebar.controller.shutdown() }
        var world = SignalWorld(); let signal = world.signal()
        var task = sidebar.tasks[0]
        task.windowId = "header-worker"
        task.signalTask = SignalTask(signal: signal, item: world.ticket().item, startedAt: Date())
        task.signalTask?.takenOver = true
        let session = SessionInfo.make("header-worker", window: "header-worker", task: task.id)
        sidebar.controller.workspace.mutate { $0.signals = world.state.signals; $0.tasks[0] = task }
        sidebar.controller.live.sessions = [session]
        // OPERATOR folded by default, so the rows are the projects' as before.
        sidebar.settleRows { sidebar.list.numberOfRows == 13 }
        sidebar.counter.reset()
        var changed = session; changed.state = .working
        sidebar.controller.live.sessions = [changed]
        sidebar.settleRows { sidebar.counter.counts[task.id] != nil }
        print("Section heading status redraws: \(sidebar.counter.headings)")
        #expect(sidebar.counter.headings["operator"] ?? 0 == 0, "baseline 1; final 0")
        #expect(sidebar.counter.headings["projects"] ?? 0 == 0, "baseline 1; final 0")
    }

}
