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

    /// A checkout monitor's scan that reads nothing: no git runs, and no branch or diff moves.
    static let noScan: CheckoutMonitor.Scanner = { _, _, _, _, _, _ in
        WorkspaceScan(branchByCwd: [:], projectBranch: [:], missingCheckouts: [], removedTasks: [], remotes: [:])
    }

    /// The commands `git` was asked for since `mark`, by their first two words.
    static func commands(_ git: RecordingGitRunner, since mark: Int) -> [String] {
        git.calls.dropFirst(mark).map { $0.args.prefix(2).joined(separator: " ") }
    }

    /// Whether fixture timings are measured: only when `AITERM_MEASURE` is set. They print, and assert nothing.
    nonisolated static var measuring: Bool { ProcessInfo.processInfo.environment["AITERM_MEASURE"] != nil }

    static func workspace() -> AppState {
        var world = SignalWorld(); let signal = world.signal(); _ = world.workingTask(signal: signal)
        return world.state
    }

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

/// Work budgets outside the Operator's tools: sidebar, window, Archive and restore costs,
/// counted by `WorkMeter` or recording git rather than elapsed time. A cheaper operation lowers its budget.
@MainActor @Suite(.blocking) struct WorkBudgetTests {
    // MARK: - The sidebar's rows

    /// Sidebar derivation shares request and worker-tab readings among all rows.

    // MARK: - The window lock

    /// Ten context-only session events cause no window reconciler passes. A pass starts only when its inputs move.
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
                controller.helper.handle(.sessionChanged(tab))
            }
        }

        #expect(controller.state.task(id: task.id)?.windowId == "w", "the row keeps its window")
        #expect(work[.reconcilerPass, default: 0] == 0, "passes for 10 events: \(work)")
    }

    /// Five checkout polls with every row in its window cause no window reconciler passes.
    @Test func pollsWithNothingOwedPassTheWindowLockNever() async throws {
        let controller = AppController(preferences: .scratch(), checkoutPollInterval: .milliseconds(10), scan: Budget.noScan)
        defer { controller.shutdown() }
        try controller.workspace.load()
        let project = Project.make(path: "/repo")
        let task = TaskItem.make(project: project.id, title: "a", worktreePath: "/repo/a", windowId: "w")
        controller.workspace.mutate { $0.append(project: project); $0.tasks = [task] }
        controller.helper.setDaemonClient(RecordingDaemon())
        let tab = SessionInfo.make("s", window: "w", task: task.id, state: .working, cwd: "/repo/a")
        controller.helper.handle(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [tab], usage: .empty)))
        await controller.windows.lastRestore?.value
        var polls = 0
        controller.checkouts.onPolled { polls += 1 }

        let work = await Budget.metered {
            controller.checkouts.startMonitoring()
            await eventually(describing: "five polls") { polls >= 5 }
            controller.checkouts.stop()
        }

        #expect(work[.reconcilerPass, default: 0] == 0, "passes for \(polls) polls with nothing owed: \(work)")
    }

    // MARK: - Archive and restore

    /// Archiving a clean open task uses eight git spawns. Restoring it uses four: one worktree listing,
    /// two rev-parse calls and worktree add.
    @Test func archivingAndRestoringATaskSpawnsGit() async throws {
        let git = RecordingGitRunner(forwardingTo: GitRunner.hermetic())
        let fixture = try await RaceFixture(scan: Budget.noScan, controllerGit: git)
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")

        var mark = git.calls.count
        await (await controller.archiver.archive(task: task))?.value
        let archive = Budget.commands(git, since: mark)
        #expect(controller.state.archive.map(\.id) == [task.id], "archived")

        controller.helper.handle(.snapshot(ControllerSnapshots.empty))
        await controller.windows.lastRestore?.value
        mark = git.calls.count
        await controller.archiver.restore(task.id)?.value
        await controller.windows.lastRestore?.value
        let restore = Budget.commands(git, since: mark)
        #expect(controller.state.tasks.map(\.id) == [task.id], "restored")

        #expect(archive.count == 8, "spawns per Archive: \(archive)")
        #expect(archive.filter { $0 == "worktree list" }.count == 4, "\(archive)")
        #expect(restore.count == 4, "spawns per restore: \(restore)")
        #expect(restore.filter { $0 == "worktree list" }.count == 1, "\(restore)")
    }

    /// Removing a clean open task while keeping its branch uses seven git spawns: three worktree listings,
    /// one status, then worktree unlock, worktree remove and worktree prune.
    @Test func removingATaskSpawnsGit() async throws {
        let git = RecordingGitRunner(forwardingTo: GitRunner.hermetic())
        let fixture = try await RaceFixture(prompter: ScriptedPrompter(answering: "Remove"), scan: Budget.noScan, controllerGit: git)
        let server = RecordingDaemon()
        defer { fixture.controller.shutdown(); fixture.cleanUp() }
        let controller = fixture.controller
        controller.helper.setDaemonClient(server)
        let task = try await fixture.addTask(windowId: "alive")

        let mark = git.calls.count
        await (await controller.remover.confirmRemove(task: task))?.value
        let remove = Budget.commands(git, since: mark)
        #expect(controller.state.task(id: task.id) == nil, "removed")

        #expect(remove.count == 7, "spawns per Remove: \(remove)")
        #expect(remove.filter { $0 == "worktree list" }.count == 3, "\(remove)")
    }

    // MARK: - Saving

    /// Saving over an existing workspace writes one file; its backup is a clone of the file it replaces.
    @Test func aSaveOverAnEarlierOneWritesItsFiles() throws {
        let state = Budget.workspace()
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

    /// The frozen workspace padded with 500 archived tasks, saved 20 times: the median, printed. Never asserted, and no
    /// installed-app latency: a fixture timing on this machine, for deciding whether the save on the main actor stalls.
    @Test(.enabled(if: Budget.measuring)) func savingTheFrozenWorkspaceWith500ArchivedTasks() throws {
        var state = Budget.workspace()
        let project = try #require(state.tasks.first?.projectId)
        state.archive = (0..<500).map { n in
            ArchivedTask(task: .make(project: project, title: "Archived task \(n)", branch: "feat/archived-\(n)",
                                     worktreePath: "/synthetic/aiterm/shop/.worktrees/archived-\(n)",
                                     firstPrompt: "Do the archived work number \(n), as the ticket says."),
                         archivedAt: Build.epoch.addingTimeInterval(Double(n)))
        }
        let folder = try ScratchFolder.make("aiterm-budget-save-")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(url: folder.appendingPathComponent("state.json"))
        try store.save(state)
        let median = try Budget.median(of: 20) { try store.save(state) }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: store.url.path)[.size] as? Int) ?? 0
        print("AITERM_MEASURE StateStore.save, frozen state + 500 archived tasks (\(bytes) bytes): median of 20 = \(String(format: "%.2f", median)) ms")
    }

    /// One `run_status` build (`OperatorController.status`) for a workspace with 20 working tasks, each with its worker and
    /// two extra tabs listed: 60 sessions. The median of 200, printed; never asserted.

}
