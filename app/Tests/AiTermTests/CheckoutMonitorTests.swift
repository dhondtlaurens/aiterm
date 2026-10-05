import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

/// A monitor over a scripted scanner: each pass reports the next of `passes`, or the last one again.
@MainActor
struct CheckoutMonitorTests {
    private let project = Project(id: UUID(), name: "repo", path: "/repo", provider: .git, remoteUrl: nil,
                                  addedAt: Date(), collapsed: false)

    private func task(_ name: String) -> TaskItem {
        TaskItem(id: UUID(), projectId: project.id, title: name, branch: "feat/\(name)", worktreePath: "/repo/.worktrees/\(name)",
                 baseBranch: "main", jira: nil, agent: .claude, model: "opus", reasoning: nil, firstPrompt: nil,
                 appendTicket: false, createdAt: Date(), windowId: nil)
    }

    private func scanning(_ passes: [WorkspaceScan]) -> CheckoutMonitor.Scanner {
        let script = Script(passes)
        return { _, _, _, _, _, _, _ in script.next() }
    }

    /// What a pass finds for the saved workspace goes back to it: the remotes, the tasks whose
    /// checkout is gone, and the tabs' titles, with the tabs they were read from.
    @Test func aPassHandsWhatItFoundToTheWorkspace() async {
        let removed = task("gone")
        var state = AppState.empty
        state.append(project: project)
        state.tasks = [removed]
        let tab = SessionInfo(sessionId: "s", windowId: "w", tabIndex: 0, taskId: removed.id.uuidString, projectId: nil,
                              agent: .claude, model: nil, state: .idle, title: "", cwd: "/repo")
        let remote = WorkspaceScan.Remote(provider: .gitlab, url: "git@gitlab.example/repo.git")
        let found = WorkspaceScan(branchByCwd: ["/repo": "main"], projectBranch: [project.id: "main"],
                                  missingCheckouts: [removed.id], removedTasks: [removed], remotes: [project.id: remote],
                                  defaultBranch: [project.id: "develop"])
        var remotes: [[UUID: WorkspaceScan.Remote]] = [], removedTasks: [[TaskItem]] = []
        var titles: [([SessionTitle], [SessionInfo])] = []
        let live = LiveSessions(workspace: { state }, sessionsChanged: { _ in })
        live.sessions = [tab]
        let monitor = CheckoutMonitor(live: live, scan: scanning([found]), workspace: { state },
                                      removalInFlight: { _ in false },
                                      onRemotes: { remotes.append($0) }, onRemovedTasks: { removedTasks.append($0) },
                                      onTitles: { titles.append(($0, $1)) })

        await monitor.refresh().value
        await monitor.titleSync?.value

        #expect(monitor.branchByCwd == ["/repo": "main"] && monitor.projectBranch == [project.id: "main"])
        #expect(monitor.missingCheckouts == [removed.id])
        #expect(monitor.defaultBranch == [project.id: "develop"])
        #expect(remotes == [[project.id: remote]])
        #expect(removedTasks == [[removed]])
        #expect(titles.map(\.0) == [[SessionTitle(sessionId: "s", title: "main")]])
        #expect(titles.map(\.1) == [[tab]])
    }

    private func result(_ branch: String) -> WorkspaceScan {
        WorkspaceScan(branchByCwd: ["/repo": branch], projectBranch: [project.id: branch],
                      missingCheckouts: [], removedTasks: [], remotes: [:])
    }

    /// Waits, off the main actor's turn, until the scanner reports it started its `count`th pass.
    private func waitForPass(_ count: Int, of scans: ScanLog) async throws {
        let deadline = TestDeadline.fromNow()
        while scans.started < count, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(scans.started >= count)
    }

    /// A refresh that arrives while a pass is out changes none of what the pass reads, so the pass
    /// is not obsolete: its answer is applied, and no second pass is run to replace it.
    @Test func aRefreshWithUnchangedInputsDoesNotDiscardThePassInFlight() async throws {
        var state = AppState.empty
        state.append(project: project)
        let scans = ScanLog(holding: true)
        let live = LiveSessions(workspace: { state }, sessionsChanged: { _ in })
        let monitor = CheckoutMonitor(live: live, scan: scans.scanner([result("main")]), workspace: { state },
                                      removalInFlight: { _ in false },
                                      onRemotes: { _ in }, onRemovedTasks: { _ in }, onTitles: { _, _ in })

        let pass = monitor.refresh()
        try await waitForPass(1, of: scans)
        monitor.refresh()
        scans.release()
        await pass.value

        #expect(monitor.branchByCwd == ["/repo": "main"])
        #expect(scans.started == 1)
    }

    /// The tick that livelocked the monitor: a pass longer than the interval used to be thrown away
    /// by the next tick, over and over, so nothing it found was ever shown.
    @Test func aPassSlowerThanThePollIntervalStillAppliesItsResult() async throws {
        var state = AppState.empty
        state.append(project: project)
        let scans = ScanLog(delay: 0.15)
        let live = LiveSessions(workspace: { state }, sessionsChanged: { _ in })
        let monitor = CheckoutMonitor(live: live, scan: scans.scanner([result("main")]), pollInterval: .milliseconds(10),
                                      workspace: { state }, removalInFlight: { _ in false },
                                      onRemotes: { _ in }, onRemovedTasks: { _ in }, onTitles: { _, _ in })
        defer { monitor.stop() }

        monitor.startMonitoring()
        let deadline = TestDeadline.fromNow()
        while monitor.branchByCwd.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }

        #expect(monitor.branchByCwd == ["/repo": "main"])
    }

    /// The pause counts from the end of a pass, not from its start: a slow pass is not followed
    /// at once by the next.
    @Test func thePollWaitsTheIntervalAfterEachPassEnds() async throws {
        var state = AppState.empty
        state.append(project: project)
        let scans = ScanLog(delay: 0.1)
        let live = LiveSessions(workspace: { state }, sessionsChanged: { _ in })
        let monitor = CheckoutMonitor(live: live, scan: scans.scanner([result("main")]), pollInterval: .milliseconds(400),
                                      workspace: { state }, removalInFlight: { _ in false },
                                      onRemotes: { _ in }, onRemovedTasks: { _ in }, onTitles: { _, _ in })
        defer { monitor.stop() }

        monitor.startMonitoring()
        try await waitForPass(1, of: scans)
        try await Task.sleep(for: .milliseconds(300)) // Past the first pass's end, short of the interval after it.

        #expect(scans.started == 1)
    }

    /// What the pass read — the tabs' directories, the projects and the tasks — moved while it
    /// ran, so what it found is of a workspace that is gone: it is dropped, and a pass reads again.
    @Test func aPassWhoseInputsChangedWhileItRanIsDiscardedAndRunAgain() async throws {
        var state = AppState.empty
        state.append(project: project)
        let scans = ScanLog(holding: true)
        var remotes = 0
        let live = LiveSessions(workspace: { state }, sessionsChanged: { _ in })
        let monitor = CheckoutMonitor(live: live, scan: scans.scanner([result("stale"), result("fresh")]), workspace: { state },
                                      removalInFlight: { _ in false },
                                      onRemotes: { _ in remotes += 1 }, onRemovedTasks: { _ in }, onTitles: { _, _ in })

        let pass = monitor.refresh()
        try await waitForPass(1, of: scans)
        state.tasks = [task("added")]
        monitor.refresh()
        scans.release()
        await pass.value

        #expect(monitor.branchByCwd == ["/repo": "fresh"])
        #expect(scans.started == 2)
        #expect(remotes == 1) // Only the second pass's answer reached the workspace.
    }

    /// The tabs' directories are inputs as much as the saved workspace: an agent that moved into a
    /// worktree mid-pass makes the pass's branches obsolete.
    @Test func aTabThatMovedDirectoryWhileAPassRanDiscardsIt() async throws {
        var state = AppState.empty
        state.append(project: project)
        let scans = ScanLog(holding: true)
        let tab = SessionInfo(sessionId: "s", windowId: "w", tabIndex: 0, taskId: nil, projectId: nil,
                              agent: .claude, model: nil, state: .idle, title: "", cwd: "/repo")
        let live = LiveSessions(workspace: { state }, sessionsChanged: { _ in })
        live.sessions = [tab]
        let monitor = CheckoutMonitor(live: live, scan: scans.scanner([result("stale"), result("fresh")]), workspace: { state },
                                      removalInFlight: { _ in false },
                                      onRemotes: { _ in }, onRemovedTasks: { _ in }, onTitles: { _, _ in })

        let pass = monitor.refresh()
        try await waitForPass(1, of: scans)
        var moved = tab
        moved.agentCwd = "/repo/.worktrees/work"
        live.sessions = [moved]
        monitor.refresh()
        scans.release()
        await pass.value

        #expect(monitor.branchByCwd == ["/repo": "fresh"])
        #expect(scans.started == 2)
    }

    /// The title RPC is a socket round trip. A refresh after a create or a forget must not queue
    /// behind it, and the titles of the passes that ran meanwhile are sent as one, the latest.
    @Test func aRefreshIsNotBlockedByATitleSyncInFlight() async throws {
        var state = AppState.empty
        state.append(project: project)
        let tab = SessionInfo(sessionId: "s", windowId: "w", tabIndex: 0, taskId: nil, projectId: project.id.uuidString,
                              agent: .claude, model: nil, state: .idle, title: "", cwd: "/repo")
        let scans = ScanLog()
        var sent: [[SessionTitle]] = []
        var inFlight: CheckedContinuation<Void, Never>?
        let live = LiveSessions(workspace: { state }, sessionsChanged: { _ in })
        live.sessions = [tab]
        let monitor = CheckoutMonitor(live: live, scan: scans.scanner([result("one"), result("two"), result("three")]),
                                      workspace: { state }, removalInFlight: { _ in false },
                                      onRemotes: { _ in }, onRemovedTasks: { _ in },
                                      onTitles: { titles, _ in
            sent.append(titles)
            if sent.count == 1 { await withCheckedContinuation { inFlight = $0 } }
        })

        await monitor.refresh().value
        await monitor.refresh().value
        await monitor.refresh().value

        #expect(monitor.branchByCwd == ["/repo": "three"])
        #expect(sent.map { $0.map(\.title) } == [["one"]]) // The first RPC is still out; the rest wait behind it.
        try #require(inFlight != nil)
        inFlight?.resume()
        await monitor.titleSync?.value

        #expect(sent.map { $0.map(\.title) } == [["one"], ["three"]])
    }

    /// A pass still out when the monitor stops is cancelled; a refresh after a restart must run a
    /// pass of its own rather than join that one and have its answer dropped.
    @Test func aRefreshAfterARestartIsNotLostToThePassStopCancelled() async {
        var state = AppState.empty
        state.append(project: project)
        let found = WorkspaceScan(branchByCwd: ["/repo": "main"], projectBranch: [project.id: "main"],
                                  missingCheckouts: [], removedTasks: [], remotes: [:])
        let release = DispatchSemaphore(value: 0)
        let live = LiveSessions(workspace: { state }, sessionsChanged: { _ in })
        let monitor = CheckoutMonitor(live: live, scan: { _, _, _, _, _, _, _ in _ = release.wait(timeout: .now() + 10); return found },
                                      workspace: { state }, removalInFlight: { _ in false },
                                      onRemotes: { _ in }, onRemovedTasks: { _ in }, onTitles: { _, _ in })

        let stopped = monitor.refresh()
        monitor.stop()
        let restarted = monitor.refresh()
        release.signal(); release.signal()
        await stopped.value
        await restarted.value
        #expect(monitor.branchByCwd == ["/repo": "main"])
    }

    /// A task whose removal is running keeps the diff it had while its checkout goes; any other
    /// missing checkout loses its diff with the pass that finds it gone.
    @Test func aTaskBeingRemovedKeepsItsDiffWhileItsCheckoutIsMissing() async {
        let removing = task("removing"), vanished = task("vanished")
        var state = AppState.empty
        state.append(project: project)
        state.tasks = [removing, vanished]
        let diff = DiffStat(added: 4, removed: 1)
        let present = WorkspaceScan(branchByCwd: [:], projectBranch: [:], missingCheckouts: [], removedTasks: [], remotes: [:],
                                    diffByTask: [removing.id: diff, vanished.id: diff])
        let missing = WorkspaceScan(branchByCwd: [:], projectBranch: [:], missingCheckouts: [removing.id, vanished.id],
                                    removedTasks: [], remotes: [:])
        let live = LiveSessions(workspace: { state }, sessionsChanged: { _ in })
        let monitor = CheckoutMonitor(live: live, scan: scanning([present, missing]), workspace: { state },
                                      removalInFlight: { $0 == removing.id },
                                      onRemotes: { _ in }, onRemovedTasks: { _ in }, onTitles: { _, _ in })

        await monitor.refresh().value
        #expect(monitor.diffByTask == [removing.id: diff, vanished.id: diff])
        await monitor.refresh().value
        #expect(monitor.diffByTask == [removing.id: diff])
        monitor.dropDiff(for: removing.id)
        #expect(monitor.diffByTask.isEmpty)
    }
}

/// The scanner runs off the main actor, so the scripted passes are handed out under a lock.
///
/// Unchecked because its stored `var`s are mutable: every access holds `lock`.
private final class Script: @unchecked Sendable {
    private let lock = NSLock()
    private var passes: [WorkspaceScan]

    init(_ passes: [WorkspaceScan]) { self.passes = passes }

    func next() -> WorkspaceScan {
        lock.lock(); defer { lock.unlock() }
        return passes.count > 1 ? passes.removeFirst() : passes[0]
    }
}

/// What the scanner was asked, counted under a lock because it runs off the main actor. `holding`
/// makes each pass wait for ``release()``; `delay` makes it take that many seconds.
///
/// Unchecked because its stored `var`s are mutable: every access holds `lock`.
private final class ScanLog: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let holding: Bool, delay: TimeInterval
    private var count = 0
    private var passes: [WorkspaceScan] = []

    init(holding: Bool = false, delay: TimeInterval = 0) { self.holding = holding; self.delay = delay }

    var started: Int { lock.lock(); defer { lock.unlock() }; return count }

    func release() { gate.signal() }

    func scanner(_ passes: [WorkspaceScan]) -> CheckoutMonitor.Scanner {
        lock.lock(); self.passes = passes; lock.unlock()
        return { [self] _, _, _, _, _, _, _ in
            let pass = begin()
            if holding, pass == 0 { _ = gate.wait(timeout: .now() + 10) }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return result(pass)
        }
    }

    private func begin() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count - 1
    }

    private func result(_ pass: Int) -> WorkspaceScan {
        lock.lock(); defer { lock.unlock() }
        return passes[min(pass, passes.count - 1)]
    }
}
