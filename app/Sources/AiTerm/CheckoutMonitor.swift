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
    /// Set by every `refresh()`, so a request that arrives mid-pass gets a pass of its own.
    @ObservationIgnored private var dirty = false
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
    private let branches = BranchResolver()
    private let remotes = RemoteResolver()
    private let diffs = DiffStatResolver()
    private let defaultBranches = DefaultBranchResolver()
    private let live: LiveSessions
    /// The saved workspace a pass reads, and where what it finds for that workspace goes: remotes
    /// to adopt, tasks whose checkout is gone, the tab titles to send. `removalInFlight` says which
    /// tasks are being removed, whose badge holds still while their checkout goes.
    private let workspace: @MainActor () -> AppState
    private let removalInFlight: @MainActor (UUID) -> Bool
    private let onRemotes: @MainActor ([UUID: WorkspaceScan.Remote]) -> Void
    private let onRemovedTasks: @MainActor ([TaskItem]) -> Void
    private let onTitles: @MainActor (_ titles: [SessionTitle], _ sessions: [SessionInfo]) async -> Void

    init(live: LiveSessions, scan: @escaping Scanner,
         workspace: @escaping @MainActor () -> AppState,
         removalInFlight: @escaping @MainActor (UUID) -> Bool,
         onRemotes: @escaping @MainActor ([UUID: WorkspaceScan.Remote]) -> Void,
         onRemovedTasks: @escaping @MainActor ([TaskItem]) -> Void,
         onTitles: @escaping @MainActor (_ titles: [SessionTitle], _ sessions: [SessionInfo]) async -> Void) {
        self.live = live
        self.scan = scan
        self.workspace = workspace
        self.removalInFlight = removalInFlight
        self.onRemotes = onRemotes
        self.onRemovedTasks = onRemovedTasks
        self.onTitles = onTitles
    }

    /// Polls the saved checkouts until `stop()`, even when neither the agent nor the daemon sends
    /// an event.
    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled, self != nil {
                self?.refresh()
                do { try await Task.sleep(for: .seconds(2)) }
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
    }

    /// A change to the tabs can move a row's branch — an agent that entered a worktree shows up as
    /// a new `agentCwd` — so a pass runs when the change is one a pass reads (``WorkspaceScan/SessionGate``).
    func sessionsChanged(_ sessions: [SessionInfo]) {
        if sessionGate.admits(sessions) { refresh() }
    }

    /// A dirty flag guarantees a trailing pass; results from obsolete inputs are
    /// discarded rather than briefly restoring a branch the user already left.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        dirty = true
        if let refreshTask { return refreshTask }
        refreshGeneration += 1
        let generation = refreshGeneration
        let task = Task {
            defer { if refreshGeneration == generation { refreshTask = nil } }
            // A cancelled pass leaves `dirty` alone: a pass started after `stop()` is owed it.
            while dirty, !Task.isCancelled {
                dirty = false
                let state = workspace()
                let cwds = live.sessions.map(\.effectiveCwd), projects = state.projects, tasks = state.tasks
                let branches = self.branches, remotes = self.remotes, diffs = self.diffs, scan = self.scan
                let defaultBranches = self.defaultBranches
                let scanned = try? await BackgroundWork.run { scan(cwds, projects, tasks, branches, remotes, diffs, defaultBranches) }
                guard !Task.isCancelled else { return }
                guard !dirty, let scan = scanned else { continue }
                applyScan(scan)
                onRemotes(scan.remotes)
                onRemovedTasks(scan.removedTasks)
                retainDiffsDuringRemoval(scan)
                await syncTitles(scan)
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

    /// The titles read the tabs as they are after the pass, which can have moved while it ran.
    private func syncTitles(_ scan: WorkspaceScan) async {
        let sessions = live.sessions
        let titles = SidebarModel.sessionTitles(state: workspace(), sessions: sessions, branchByCwd: scan.branchByCwd,
                                                projectBranch: scan.projectBranch)
        await onTitles(titles, sessions)
    }
}
