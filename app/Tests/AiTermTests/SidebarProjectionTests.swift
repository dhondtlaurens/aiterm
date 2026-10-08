import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The sidebar's rows are derived once, for the list, the Dock badge and Focus and List View, and
/// only when a row could have changed: not for a session event that moved a fill, a model or a
/// title, nor for a sidebar move or a remembered choice, which the workspace saves but no row draws.
@MainActor
struct SidebarProjectionTests {
    private let project = Project(id: UUID(), name: "repo", path: "/repo", provider: .gitlab, remoteUrl: nil,
                                  addedAt: Date(), collapsed: false)
    private var task: TaskItem {
        TaskItem(id: Self.taskId, projectId: project.id, title: "a", branch: "feat/a", worktreePath: "/repo/a",
                 baseBranch: "main", jira: nil, agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil,
                 appendTicket: true, createdAt: Date(), windowId: "w")
    }
    private nonisolated static let taskId = UUID()

    private func tab(_ state: SessionState = .working) -> SessionInfo {
        SessionInfo(sessionId: "s", windowId: "w", tabIndex: 0, taskId: Self.taskId.uuidString, projectId: nil,
                    agent: .claude, model: nil, state: state, title: "", cwd: "/repo/a")
    }

    private func controller(scan: @escaping CheckoutMonitor.Scanner = { _, _, _, _, _, _, _ in
        WorkspaceScan(branchByCwd: [:], projectBranch: [:], missingCheckouts: [], removedTasks: [], remotes: [:])
    }) throws -> AppController {
        let controller = AppController(preferences: .scratch(), scan: scan)
        try controller.loadWorkspace()
        controller.workspace.mutate { [project, task] state in
            state.append(project: project)
            state.tasks = [task]
        }
        controller.live.handle(.sessionOpened(tab()))
        return controller
    }

    /// What the list draws from: a write that changes none of it redraws no row.
    private func readsTheList(_ rows: SidebarProjection) -> () -> Void {
        { _ = rows.entries; _ = rows.tasks; _ = rows.terminals }
    }

    /// Before: ten session events that moved only a fill, a model and a title derived the rows ten
    /// times, for the badge; ten sidebar moves or remembered choices twenty, and redrew the list ten
    /// times; and each menu validation of Focus and List View two. Now none of them derives a row.
    @Test func onlyAChangeToARowDerivesTheRowsAgain() throws {
        let controller = try controller()
        let rows = controller.rows
        let start = rows.derivations

        var event = tab()
        #expect(!invalidates(readsTheList(rows)) {
            for n in 1...10 {
                event.contextPercent = n; event.model = "model-\(n)"; event.title = "✳ step \(n)"
                controller.live.handle(.sessionChanged(event))
            }
        }, "a fill, a model or a title draws no row")
        #expect(rows.derivations == start)

        #expect(!invalidates(readsTheList(rows)) {
            for n in 1...10 { controller.workspace.mutate { $0.sidebarFrame = CGRect(x: n, y: 0, width: 300, height: 800) } }
        }, "a sidebar move draws no row")
        #expect(rows.derivations == start)

        #expect(!invalidates(readsTheList(rows)) {
            for n in 1...10 {
                controller.workspace.mutate { $0.lastAgentByProject[project.id] = n.isMultiple(of: 2) ? .claude : .codex }
                controller.workspace.mutate { $0.lastModelByAgent[.claude] = "model-\(n)" }
            }
        }, "a remembered choice draws no row")
        #expect(rows.derivations == start)

        for _ in 1...10 { _ = controller.canShowFocusView; _ = controller.canShowListView }
        #expect(rows.derivations == start, "the menus read the rows the list draws")

        event.state = .needsInput
        #expect(invalidates(readsTheList(rows)) { controller.live.handle(.sessionChanged(event)) })
        #expect(rows.derivations == start + 1, "a status change derives the rows once")
        #expect(rows.sections.first?.tasks.first?.status == .needsInput)
    }

    /// The rows are the list's whole model: what `SidebarModel.entries` makes of the workspace,
    /// the tabs as the rows read them and the checkouts on disk, kept as each of them changes.
    @Test func theRowsFollowTheWorkspaceTheTabsAndTheCheckouts() async throws {
        let controller = try controller(scan: { _, _, _, _, _, _, _ in
            WorkspaceScan(branchByCwd: ["/repo/a": "feat/moved"], projectBranch: [:], missingCheckouts: [],
                          removedTasks: [], remotes: [:], diffByTask: [Self.taskId: DiffStat(added: 3, removed: 1)])
        })
        func expected() -> [SidebarEntry] {
            SidebarModel.entries(state: controller.state, sessions: controller.live.rowSessions,
                                 branchByCwd: controller.checkouts.branchByCwd, projectBranch: controller.checkouts.projectBranch,
                                 diffByTask: controller.checkouts.diffByTask)
        }
        #expect(controller.rows.entries == expected())
        #expect(controller.rows.tasks[Self.taskId]?.title == "a")

        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Shell", windowId: "t", createdAt: Date())
        controller.workspace.mutate { $0.terminals = [terminal]; $0.append(divider: SidebarDivider(id: UUID(), name: "")) }
        #expect(controller.rows.entries == expected())
        #expect(controller.rows.terminals[terminal.id] == terminal)

        await controller.checkouts.refresh().value
        let row = try #require(controller.rows.sections.first?.tasks.first)
        #expect(row.branch.name == "feat/moved" && row.branch.drifted, "a pass that moved the branch redraws the row")
        #expect(row.diff?.stat == DiffStat(added: 3, removed: 1))
        #expect(controller.rows.entries == expected())
    }

    /// The Dock badge counts the rows the list draws: it moves with a status, and not with a fill
    /// or a sidebar move.
    @Test func theBadgeCountsTheDerivedRows() throws {
        var written: [String?] = []
        let controller = AppController(preferences: .scratch(), setBadge: { written.append($0) })
        try controller.loadWorkspace()
        controller.workspace.mutate { [project, task] state in
            state.append(project: project)
            state.tasks = [task]
        }
        controller.live.handle(.sessionOpened(tab(.done)))
        #expect(written == ["1"])
        var event = tab(.done)
        for n in 1...5 { event.contextPercent = n; controller.live.handle(.sessionChanged(event)) }
        controller.workspace.mutate { $0.sidebarFrame = CGRect(x: 0, y: 0, width: 300, height: 800) }
        #expect(written == ["1"])
        event.state = .idle
        controller.live.handle(.sessionChanged(event))
        #expect(written == ["1", nil])
    }

    /// A removal that starts passes its task over, as Focus View does, and the task's going leaves
    /// the badge clear: its row is gone from the sections before its removal's entry goes, so the
    /// badge never counts it again in between.
    @Test func aRemovedTaskLeavesTheBadgeOnce() async throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: realpath(raw, nil).map { defer { free($0) }; return String(cString: $0) } ?? raw)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = GitRunner.hermetic(), repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git.run(["init", "-q", "-b", "main"], in: repo.path)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo.path)
        let checkout = repo.appendingPathComponent(".worktrees/work").path
        try git.run(["worktree", "add", "-q", "-b", "feat/work", checkout], in: repo.path)
        let project = Project(id: UUID(), name: "Repo", path: repo.path, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let task = TaskItem(id: Self.taskId, projectId: project.id, title: "Work", branch: "feat/work", worktreePath: checkout,
                            baseBranch: "main", jira: nil, agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil,
                            appendTicket: false, createdAt: Date(), windowId: nil)

        var written: [String?] = []
        let controller = AppController(store: StateStore(url: root.appendingPathComponent("state.json")), preferences: .scratch(),
                                       prompter: ScriptedPrompter(answering: "Remove"), setBadge: { written.append($0) }, git: git)
        try controller.loadWorkspace()
        controller.workspace.mutate { $0.append(project: project); $0.tasks = [task] }
        controller.live.handle(.sessionOpened(tab(.done)))
        #expect(written == ["1"])

        let removal = try #require(await controller.confirmRemove(task: task))
        await removal.value
        #expect(controller.state.tasks.isEmpty, "the task is removed")
        #expect(written == ["1", nil])
    }

    /// The footer's context row reads the rows' tabs and the fills: a session event that moved a fill
    /// redraws it, one that moved only a model or a title does not, and neither does a sidebar move.
    @Test func theContextRowRedrawsForAFillAlone() throws {
        let controller = try controller()
        controller.focus.browse(.task(Self.taskId))
        let footer = SelectedRowSidebarFooter(controller: controller, vendors: [])
        var event = tab()
        event.contextPercent = 40
        #expect(invalidates({ _ = footer.body }) { controller.live.handle(.sessionChanged(event)) })
        #expect(controller.rows.usageRow(for: .task(Self.taskId))?.context?.percent == 40)
        event.model = "sonnet"; event.title = "✳ thinking"
        #expect(!invalidates({ _ = footer.body }) { controller.live.handle(.sessionChanged(event)) })
        #expect(!invalidates({ _ = footer.body }) {
            controller.workspace.mutate { $0.sidebarFrame = CGRect(x: 0, y: 0, width: 300, height: 800) }
        })
    }

    /// The counts redraw the footer and nothing else: they are not part of a row, so the rows are not
    /// derived again; and a model or a title moving leaves the footer be.
    @Test func theCountsRedrawTheFooterAlone() throws {
        let controller = try controller()
        controller.focus.browse(.task(Self.taskId))
        let footer = SelectedRowSidebarFooter(controller: controller, vendors: [])
        var event = tab()
        event.active = true
        controller.live.handle(.sessionChanged(event))
        let rows = controller.live.rowSessions
        event.tokens = TokenTally(input: 936_018, cached: 935_988, output: 5_625)
        #expect(invalidates({ _ = footer.body }) { controller.live.handle(.sessionChanged(event)) })
        #expect(controller.rows.usageRow(for: .task(Self.taskId))?.tokens == event.tokens)
        #expect(controller.live.rowSessions == rows)
        event.model = "sonnet"; event.title = "✳ thinking"
        #expect(!invalidates({ _ = footer.body }) { controller.live.handle(.sessionChanged(event)) })
    }
}
