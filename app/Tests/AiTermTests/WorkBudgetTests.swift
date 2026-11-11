import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// What the work budgets share: a step counted under a meter of its own, and an Operator world let settle so that the
/// work a step starts is counted with it, and none of it spills into the next step's count.
@MainActor
enum Budget {
    /// Runs `step` with a fresh `WorkMeter` bound, and returns what it counted. Work `step` hands to a task it creates is
    /// counted too, so a step that starts some awaits it before it returns (`settle`).
    static func metered(_ step: () async throws -> Void) async rethrows -> [WorkMeter.Work: Int] {
        let meter = WorkMeter()
        try await WorkMeter.$current.withValue(meter) { try await step() }
        return meter.take()
    }

    /// Waits until the Operator's owners have finished what they started (`OperatorWork`): the turn and transcript
    /// reads, prompt probes, branch and review passes, wake lines, launches, and the work those started.
    static func settle(_ controller: OperatorController) async { await controller.ports.work.settled() }

    /// A checkout monitor's scan that reads nothing: no git runs, and no branch or diff moves.
    static let noScan: CheckoutMonitor.Scanner = { _, _, _, _, _, _, _ in
        WorkspaceScan(branchByCwd: [:], projectBranch: [:], missingCheckouts: [], removedTasks: [], remotes: [:])
    }

    /// The commands `git` was asked for since `mark`, by their first two words.
    static func commands(_ git: RecordingGitRunner, since mark: Int) -> [String] {
        git.calls.dropFirst(mark).map { $0.args.prefix(2).joined(separator: " ") }
    }

    /// Whether fixture timings are measured: only when `AITERM_MEASURE` is set. They print, and assert nothing.
    nonisolated static var measuring: Bool { ProcessInfo.processInfo.environment["AITERM_MEASURE"] != nil }

    /// The median of `count` timings of `body`, in milliseconds.
    static func median(of count: Int, _ body: () throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        var times: [Double] = []
        for _ in 0..<count {
            let took = try clock.measure(body)
            times.append(Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15)
        }
        times.sort()
        return times.count.isMultiple(of: 2) ? (times[times.count / 2 - 1] + times[times.count / 2]) / 2 : times[times.count / 2]
    }
}

/// Work budgets outside the Operator's tools (plan 2026-11-10, phase 0): what one step of the sidebar, the window lock,
/// a Shelve and a restore costs today, counted by `WorkMeter` or a recording git, never timed. Each number is exact and
/// is today's: a later change that makes the step cheaper lowers it here, and none may raise it.
@MainActor @Suite(.blocking) struct WorkBudgetTests {
    // MARK: - The sidebar's rows

    /// One derivation of the sidebar's rows (`SidebarProjection.refresh`) for the frozen broadcast — 4 tasks, 6 extra
    /// tabs, the run active — after its working worker's tab went to needs-input, a status a row draws.
    ///
    /// 1 `OperatorRequests.open` and 4 `TaskItem.workerTabs`, board closed or open: the derivation's pass (`SidebarPass`)
    /// derives the live run's requests once and matches each of its 4 tasks' worker tabs once, and the group's header, its
    /// rows, the projects' entries and the board read them. Before it (phase 0): 3 and 5 with the board closed, the header
    /// and the operated-row lookup, built twice, deriving the requests each; 4 and 18 open, the board deriving them again
    /// and matching worker tabs 13 more times for its 4 cards. None may raise them.
    @Test(arguments: [false, true]) func aSidebarRefreshDerivesTheRequestsAndTheWorkerTabs(boardShown: Bool) async throws {
        let state = try OperatorCurrentContractTests.load()
        let workspace = WorkspaceStore.holding(state)
        let live = LiveSessions(workspace: workspace)
        var sessions = try OperatorWorkBudgetTests.frozenSessions(state)
        live.sessions = sessions
        let checkouts = CheckoutMonitor(live: live, scan: Budget.noScan, git: .hermetic(), workspace: workspace, onTitles: { _ in })
        let rows = SidebarProjection(workspace: workspace, live: live, checkouts: checkouts)
        rows.boardShown = { boardShown }
        rows.refresh()
        #expect((rows.board != nil) == boardShown)
        let working = try #require(state.tasks.first { $0.operated?.state == .working })
        let worker = try #require(sessions.firstIndex { $0.taskUUID == working.id && $0.tabIndex == 0 })
        sessions[worker].state = .needsInput
        live.sessions = sessions
        let start = rows.derivations

        let work = await Budget.metered { rows.refresh() }

        #expect(rows.derivations == start + 1, "one derivation")
        #expect(work[.requests] == 1, "requests per refresh: \(work)")
        #expect(work[.workerTabs] == 4, "worker-tab matches per refresh: \(work)")
    }

    // MARK: - The window lock

    /// Ten `session.changed` events for a task's tab that move only its context fill and its title, which no row draws,
    /// through the app's own routing (`HelperLink.handle`): 10 `WindowReconciler` passes, one per event, though none
    /// has anything to do. A later change that passes only when a row's window could have changed lowers it; none may
    /// raise it.
    @Test func sessionEventsThatChangeNoRowEachPassTheWindowLock() async throws {
        let controller = AppController(preferences: .scratch(), scan: Budget.noScan)
        defer { controller.shutdown() }
        try controller.workspace.load()
        let project = Project.make(path: "/repo")
        let task = TaskItem.make(project: project.id, title: "a", worktreePath: "/repo/a", windowId: "w")
        controller.workspace.mutate { $0.append(project: project); $0.tasks = [task] }
        controller.helper.setDaemonClient(RecordingDaemon())
        var tab = SessionInfo.make("s", window: "w", task: task.id, state: .working, cwd: "/repo/a")
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [tab], usage: .empty)))
        await controller.windows.lastRestore?.value

        let work = await Budget.metered {
            for n in 1...10 {
                tab.contextPercent = n * 5
                tab.title = "✳ step \(n)"
                controller.helper.handle(.sessionChanged(tab))
            }
        }

        #expect(controller.state.task(id: task.id)?.windowId == "w", "the row keeps its window")
        #expect(work[.reconcilerPass] == 10, "passes for 10 events: \(work)")
    }

    // MARK: - Shelve and restore

    /// Shelving a task with a clean worktree and an open window, then restoring it from the Shelf, as git sees it: the
    /// controller's own git, the checkout monitor's scan reading nothing.
    ///
    /// Shelve: 9 spawns, `worktree list` five times (three before and two after the `status --porcelain` that looks for
    /// unsaved work), then `worktree unlock`, `worktree remove` and `worktree prune`. Restore: 4 spawns, one `worktree
    /// list`, then 2 `rev-parse` and `worktree add` (6 before phase 2 listed the worktrees once per restore, 3 `worktree
    /// list`). A later change that lists the worktrees once per Shelve lowers that number; none may raise them.
    @Test func shelvingAndRestoringATaskSpawnsGit() async throws {
        let git = RecordingGitRunner(forwardingTo: GitRunner.hermetic())
        let fixture = try RaceFixture(scan: Budget.noScan, controllerGit: git)
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try fixture.addTask(windowId: "alive")

        var mark = git.calls.count
        await (await controller.archiver.archive(task: task))?.value
        let shelve = Budget.commands(git, since: mark)
        #expect(controller.state.archive.map(\.id) == [task.id], "shelved")

        controller.helper.handle(.snapshot(AppControllerTests.emptySnapshot))
        await controller.windows.lastRestore?.value
        mark = git.calls.count
        await controller.archiver.restore(task.id)?.value
        await controller.windows.lastRestore?.value
        let restore = Budget.commands(git, since: mark)
        #expect(controller.state.tasks.map(\.id) == [task.id], "restored")

        #expect(shelve.count == 9, "spawns per Shelve: \(shelve)")
        #expect(restore.count == 4, "spawns per restore: \(restore)")
        #expect(restore.filter { $0 == "worktree list" }.count == 1, "\(restore)")
    }

    // MARK: - Saving

    /// A save of the frozen workspace over the one it saved before: 1 file written, the workspace; the backup is a clone
    /// of the file it replaces (2 before phase 2, when the backup was written as bytes too). None may raise it.
    @Test func aSaveOverAnEarlierOneWritesItsFiles() throws {
        let state = try OperatorCurrentContractTests.load()
        let folder = try ScratchFolder.make("aiterm-budget-writes-")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(url: folder.appendingPathComponent("state.json"))
        try store.save(state)
        let first = try Data(contentsOf: store.url)
        let meter = WorkMeter()
        try WorkMeter.$current.withValue(meter) { try store.save(state) }
        #expect(meter[.stateWrite] == 1, "files written per save: \(meter.take())")
        #expect(try Data(contentsOf: store.backupURL) == first, "the backup is the save before")
        #expect(try Data(contentsOf: store.url) == first)
    }

    // MARK: - Fixture timings, printed only

    /// The frozen workspace padded with 500 shelved tasks, saved 20 times: the median, printed. Never asserted, and no
    /// installed-app latency: a fixture timing on this machine, for deciding whether the save on the main actor stalls.
    @Test(.enabled(if: Budget.measuring)) func savingTheFrozenWorkspaceWith500ShelvedTasks() throws {
        var state = try OperatorCurrentContractTests.load()
        let project = try #require(state.tasks.first?.projectId)
        state.archive = (0..<500).map { n in
            ArchivedTask(task: .make(project: project, title: "Shelved task \(n)", branch: "feat/shelved-\(n)",
                                     worktreePath: "/synthetic/aiterm/shop/.worktrees/shelved-\(n)",
                                     firstPrompt: "Do the shelved work number \(n), as the ticket says."),
                         archivedAt: Build.epoch.addingTimeInterval(Double(n)))
        }
        let folder = try ScratchFolder.make("aiterm-budget-save-")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(url: folder.appendingPathComponent("state.json"))
        try store.save(state)
        let median = try Budget.median(of: 20) { try store.save(state) }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: store.url.path)[.size] as? Int) ?? 0
        print("AITERM_MEASURE StateStore.save, frozen state + 500 shelved tasks (\(bytes) bytes): median of 20 = \(String(format: "%.2f", median)) ms")
    }

    /// One `run_status` build (`OperatorController.status`) for a broadcast of 20 working tasks, each with its worker and
    /// two extra tabs listed: 60 sessions. The median of 200, printed; never asserted.
    @Test(.enabled(if: Budget.measuring)) func buildingTheStatusOfTwentyTasksAndSixtySessions() throws {
        let project = Project.make(path: "/synthetic/aiterm/shop")
        let run = OperatorRun.make(profile: OperatorServiceFixtures.profile(), projects: [project.id])
        var sessions: [SessionInfo] = []
        let tasks = (0..<20).map { n -> TaskItem in
            let id = UUID()
            let extras = (1...2).map { k in
                ExtraTab(key: "tab-\(k)", agent: .codex, model: "gpt-6-astra", reasoning: "medium", modelReason: "Cheap enough.",
                         brief: "Help with part \(k).", launch: LaunchAttempt(number: 1, requestedAt: Build.epoch, openedAt: Build.epoch),
                         sessionId: "extra-\(n)-\(k)", conversation: "conversation-\(n)-\(k)")
            }
            var operated = OperatedTask.make(run: run.id, key: "SHOP-\(n)", state: .working, launched: true)
            operated.extraTabs = extras
            sessions.append(.make("main-\(n)", window: "window-\(n)", task: id, state: .working,
                                  cwd: "/synthetic/aiterm/shop/.worktrees/shop-\(n)", conversation: "conversation-\(n)"))
            for k in 1...2 {
                sessions.append(.make("extra-\(n)-\(k)", window: "window-\(n)", tabIndex: k, task: id, agent: .codex, state: .idle,
                                      cwd: "/synthetic/aiterm/shop/.worktrees/shop-\(n)", conversation: "conversation-\(n)-\(k)",
                                      tabKey: "tab-\(k)"))
            }
            return .make(id: id, project: project.id, title: "Task SHOP-\(n)", branch: "feat/shop-\(n)",
                         worktreePath: "/synthetic/aiterm/shop/.worktrees/shop-\(n)", operated: operated)
        }
        var state = AppState.empty
        state.append(project: project)
        state.runs = [run]
        state.tasks = tasks
        #expect(sessions.count == 60)
        #expect(OperatorController.status(of: run.id, state: state, sessions: sessions, revision: 0, turns: [:])?.tasks.count == 20)
        let median = Budget.median(of: 200) {
            _ = OperatorController.status(of: run.id, state: state, sessions: sessions, revision: 0, turns: [:], now: Build.epoch)
        }
        print("AITERM_MEASURE OperatorController.status, 20 tasks and 60 sessions: median of 200 = \(String(format: "%.3f", median)) ms")
    }
}
