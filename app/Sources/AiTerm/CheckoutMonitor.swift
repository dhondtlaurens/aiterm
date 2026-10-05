import Foundation
import AiTermCore

/// What the checkouts on disk say: the branch in every tab's directory and every project, which
/// tasks' worktrees are missing, and each task's diff against its base. Read by a pass off the main
/// actor — on every session change a pass reads, and every two seconds besides, because a deleted
/// checkout can stop the agent's last hook from ever reporting it. What a pass finds that belongs
/// to the saved workspace — a remote, a removed task — goes back to its owner.
@MainActor
@Observable
final class CheckoutMonitor {
    /// Every directory a tab is in, mapped to the branch checked out there. `BranchResolver` makes
    /// a pass a `stat` per directory rather than a git call.
    private(set) var branchByCwd: [String: String] = [:]
    /// Each project's own checkout, for rows whose window is closed and have no tab to read.
    private(set) var projectBranch: [UUID: String] = [:]
    private(set) var missingCheckouts: Set<UUID> = []
    /// Each task's checkout against its base, for the VS Code badge. Measured by the same pass as
    /// the branches, but at most every few seconds per worktree (``DiffStatResolver``).
    private(set) var diffByTask: [UUID: DiffStat] = [:]
    /// Each project's default branch, which the menu's "Pull main" names.
    private(set) var defaultBranch: [UUID: String] = [:]
    /// The pass in flight, if any; tests await it, or check that nothing started one.
    @ObservationIgnored private(set) var refreshTask: Task<Void, Never>?
    /// The title sync in flight, if any; tests await it. A pass hands its titles to it rather than
    /// awaiting the daemon, so a refresh never queues behind the round trip.
    @ObservationIgnored private(set) var titleSync: Task<Void, Never>?
    /// The titles of the latest pass that ended while a sync was out, sent when it returns. Passes
    /// that end meanwhile replace it: only the newest titles are worth sending.
    @ObservationIgnored private var pendingTitles: (titles: [SessionTitle], sessions: [SessionInfo])?
    /// Set by a `refresh()` that joins a pass in flight: its caller changed the disk just before
    /// asking, and the pass may have looked before, so one more follows the pass once it is applied.
    @ObservationIgnored private var trailingPassOwed = false
    /// Which `refresh` pass is the current one: a pass `stop()` cancelled must not clear the
    /// `refreshTask` of one started after it.
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var sessionGate = WorkspaceScan.SessionGate()
    @ObservationIgnored private var monitor: Task<Void, Never>?

    /// What a pass runs off the main actor: ``WorkspaceScan/run(cwds:projects:tasks:branches:remotes:diffs:defaultBranches:)``,
    /// except in the tests that count passes.
    typealias Scanner = @Sendable (_ cwds: [String], _ projects: [Project], _ tasks: [TaskItem],
                                   _ branches: BranchResolver, _ remotes: RemoteResolver, _ diffs: DiffStatResolver,
                                   _ defaultBranches: DefaultBranchResolver) -> WorkspaceScan
    private let scan: Scanner
    /// The pause between one pass ending and the next starting.
    private let pollInterval: Duration
    private let branches: BranchResolver
    private let remotes: RemoteResolver
    private let diffs: DiffStatResolver
    private let defaultBranches: DefaultBranchResolver
    private let stalls: StallGuardedGit
    private let live: LiveSessions
    /// The saved workspace a pass reads, and where what it finds for that workspace goes: remotes
    /// to adopt, tasks whose checkout is gone, the tab titles to send. `removalInFlight` says which
    /// tasks are being removed, whose badge holds still while their checkout goes.
    private let workspace: @MainActor () -> AppState
    private let removalInFlight: @MainActor (UUID) -> Bool
    private let onRemotes: @MainActor ([UUID: WorkspaceScan.Remote]) -> Void
    private let onRemovedTasks: @MainActor ([TaskItem]) -> Void
    private let onTitles: @MainActor (_ titles: [SessionTitle], _ sessions: [SessionInfo]) async -> Void

    init(live: LiveSessions, scan: @escaping Scanner, pollInterval: Duration = .seconds(2), git: any GitRunning,
         workspace: @escaping @MainActor () -> AppState,
         removalInFlight: @escaping @MainActor (UUID) -> Bool,
         onRemotes: @escaping @MainActor ([UUID: WorkspaceScan.Remote]) -> Void,
         onRemovedTasks: @escaping @MainActor ([TaskItem]) -> Void,
         onTitles: @escaping @MainActor (_ titles: [SessionTitle], _ sessions: [SessionInfo]) async -> Void) {
        self.live = live
        self.scan = scan
        self.pollInterval = pollInterval
        // A pass runs git through a guard that gives up on a project once one of its commands times out.
        // One probe for the three resolvers, so a directory's files are looked up once, not once each.
        let guarded = StallGuardedGit(git), probe = RepositoryProbe(git: guarded)
        stalls = guarded
        branches = BranchResolver(git: guarded, probe: probe); remotes = RemoteResolver(git: guarded, probe: probe)
        diffs = DiffStatResolver(git: guarded); defaultBranches = DefaultBranchResolver(git: guarded, probe: probe)
        self.workspace = workspace
        self.removalInFlight = removalInFlight
        self.onRemotes = onRemotes
        self.onRemovedTasks = onRemovedTasks
        self.onTitles = onTitles
    }

    /// Polls the saved checkouts until `stop()`, even when neither the agent nor the daemon sends
    /// an event. The interval is the pause after a pass ends, not the time between starts, so a pass
    /// that outlasts it is followed by a pause rather than by another pass at once.
    func startMonitoring() {
        guard monitor == nil else { return }
        let interval = pollInterval
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let pass = self?.startPass(owesTrailing: false) else { break }
                await pass.value
                do { try await Task.sleep(for: interval) }
                catch { break }
            }
        }
    }

    /// The pass under way is cancelled and let go: a `refresh()` after a restart starts its own
    /// rather than joining one whose answer will be dropped.
    func stop() {
        monitor?.cancel()
        monitor = nil
        refreshTask?.cancel()
        refreshTask = nil
        pendingTitles = nil
    }

    /// A change to the tabs can move a row's branch — an agent that entered a worktree shows up as
    /// a new `agentCwd` — so a pass runs when the change is one a pass reads (``WorkspaceScan/SessionGate``).
    func sessionsChanged(_ sessions: [SessionInfo]) {
        if sessionGate.admits(sessions) { refresh() }
    }

    /// A request that arrives while a pass is out joins it, and the pass is not obsolete for that:
    /// it is dropped, and read again, only if what it reads — the tabs' directories, the projects,
    /// the tasks — differs when it ends from what it started with, rather than briefly restoring a
    /// branch the user already left. Its answer is applied, and then a pass of the request's own
    /// follows, because callers ask right after changing the disk (a worktree removed or created)
    /// and the pass may have looked first. Only the poll's tick (`startPass(owesTrailing:)`) joins
    /// without that, since it awaits the pass anyway; a tick that discarded or repeated the pass in
    /// flight would never let a pass slower than the interval be applied.
    @discardableResult
    func refresh() -> Task<Void, Never> { startPass(owesTrailing: true) }

    private func startPass(owesTrailing: Bool) -> Task<Void, Never> {
        if let refreshTask {
            if owesTrailing { trailingPassOwed = true }
            return refreshTask
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        let task = Task {
            defer { if refreshGeneration == generation { refreshTask = nil } }
            while !Task.isCancelled {
                trailingPassOwed = false
                let inputs = ScanInputs(workspace: workspace(), cwds: live.sessions.map(\.effectiveCwd))
                let branches = self.branches, remotes = self.remotes, diffs = self.diffs, scan = self.scan
                let defaultBranches = self.defaultBranches
                stalls.scope(projects: inputs.projects, tasks: inputs.tasks)
                let scanned = try? await BackgroundWork.run {
                    scan(inputs.cwds, inputs.projects, inputs.tasks, branches, remotes, diffs, defaultBranches)
                }
                guard !Task.isCancelled, let scan = scanned else { return }
                guard inputs == ScanInputs(workspace: workspace(), cwds: live.sessions.map(\.effectiveCwd)) else { continue }
                applyScan(scan)
                onRemotes(scan.remotes)
                onRemovedTasks(scan.removedTasks)
                retainDiffsDuringRemoval(scan)
                syncTitles(scan)
                if !trailingPassOwed { return }
            }
        }
        refreshTask = task
        return task
    }

    /// A forgotten task's checkout is no longer one of the workspace's missing ones.
    func forget(task id: UUID) { missingCheckouts.remove(id) }

    /// A removal that stopped after its checkout went shows the row's diff as missing, rather than
    /// the one held while the removal ran.
    func dropDiff(for id: UUID) { diffByTask.removeValue(forKey: id) }

    #if DEBUG
    /// The snapshot renderer's checkouts, shown before its first pass (which reports the same) ends.
    func seedSnapshotFixture(_ scan: WorkspaceScan) {
        applyScan(scan)
        diffByTask = scan.diffByTask
    }
    #endif

    /// The monitor runs a pass every two seconds and nearly every pass finds nothing new. An
    /// unconditional write still tells every observer it changed, re-rendering the sidebar.
    private func applyScan(_ scan: WorkspaceScan) {
        if missingCheckouts != scan.missingCheckouts { missingCheckouts = scan.missingCheckouts }
        if branchByCwd != scan.branchByCwd { branchByCwd = scan.branchByCwd }
        if projectBranch != scan.projectBranch { projectBranch = scan.projectBranch }
        if defaultBranch != scan.defaultBranch { defaultBranch = scan.defaultBranch }
    }

    /// Keep the badge steady while removal is in flight, even if a later scan
    /// cannot re-confirm deletion because the checkout's parent goes offline.
    /// Once removal fails, the row remains and the missing diff is shown.
    private func retainDiffsDuringRemoval(_ scan: WorkspaceScan) {
        var next = scan.diffByTask
        for id in scan.missingCheckouts where removalInFlight(id) {
            if let previous = diffByTask[id] { next[id] = previous }
        }
        if diffByTask != next { diffByTask = next }
    }

    /// The titles read the tabs as they are after the pass, which can have moved while it ran. One
    /// sync is out at a time; the titles of a pass that ends meanwhile wait behind it.
    private func syncTitles(_ scan: WorkspaceScan) {
        let sessions = live.sessions
        let titles = SidebarModel.sessionTitles(state: workspace(), sessions: sessions, branchByCwd: scan.branchByCwd,
                                                projectBranch: scan.projectBranch)
        pendingTitles = (titles, sessions)
        guard titleSync == nil else { return }
        titleSync = Task {
            while let next = pendingTitles {
                pendingTitles = nil
                await onTitles(next.titles, next.sessions)
            }
            titleSync = nil
        }
    }
}

/// What a pass reads from the app: the directories of the open tabs and the saved workspace's
/// projects and tasks. A pass whose inputs differ at its end read a workspace that has since moved.
private struct ScanInputs: Equatable {
    let cwds: [String], projects: [Project], tasks: [TaskItem]

    @MainActor init(workspace: AppState, cwds: [String]) {
        self.cwds = cwds
        projects = workspace.projects
        tasks = workspace.tasks
    }
}
