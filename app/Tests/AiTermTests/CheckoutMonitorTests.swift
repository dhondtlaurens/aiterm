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

        #expect(monitor.branchByCwd == ["/repo": "main"] && monitor.projectBranch == [project.id: "main"])
        #expect(monitor.missingCheckouts == [removed.id])
        #expect(monitor.defaultBranch == [project.id: "develop"])
        #expect(remotes == [[project.id: remote]])
        #expect(removedTasks == [[removed]])
        #expect(titles.map(\.0) == [[SessionTitle(sessionId: "s", title: "main")]])
        #expect(titles.map(\.1) == [[tab]])
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
