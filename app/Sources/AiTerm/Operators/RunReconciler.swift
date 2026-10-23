import Foundation
import AiTermCore

/// Looks at the real tabs and says what it finds (spec §7.3, §8, §11): an operator whose tab has gone
/// takes its broadcast offline, and one back brings it back — never a pause or stop of yours; a worker
/// whose launch never showed a tab is launched again, but only a minute on, never while one may still
/// be starting, never while a tab tagged with it is alive, and never once its window showed — one you
/// closed comes back on your click (`OperatorController.reopenWorker`); a worker's time at work is
/// counted against its runtime, and one past it is blocked. (A worker that shows no change for twenty
/// minutes is flagged, never replaced, by `OperatorController.applyStallFlags`.) Wake lines and hooks are only hints.
@MainActor
final class RunReconciler {
    private let workspace: WorkspaceStore
    private let live: LiveSessions
    private let starter: WorkerStarter
    private let tabs: TabOpener
    private let waker: OperatorWaker
    private let ports: OperatorPorts
    /// Whether a connected snapshot has come since the helper attached (the controller's `tabsKnown`): until then, a
    /// tab not listed is not a tab gone.
    var tabsKnown: @MainActor () -> Bool = { false }
    /// The latest relaunch, for a test to await.
    private(set) var lastLaunch: Task<Void, Never>?
    /// The latest extra tab asked for again, for a test to await.
    private(set) var lastTab: Task<Void, Never>?
    /// When the last tick counted runtime; nil until the first tick after AiTerm starts, which only
    /// sets it, so the time AiTerm was not running is not counted.
    private var lastCounted: Date?
    /// When the first synced tick of this run of AiTerm came: a launch it knows no end of (it began before
    /// AiTerm started) is counted a minute from here at the soonest, so a slow iTerm2 has listed its window.
    private var firstSynced: Date?

    init(workspace: WorkspaceStore, live: LiveSessions, starter: WorkerStarter, tabs: TabOpener, waker: OperatorWaker, ports: OperatorPorts) {
        self.workspace = workspace
        self.live = live
        self.starter = starter
        self.tabs = tabs
        self.waker = waker
        self.ports = ports
    }

    private var state: AppState { workspace.state }

    /// One pass. The runs whose state it changed or in which it blocked a task, for their scheduling and completion.
    @discardableResult
    func tick() -> Set<UUID> {
        guard tabsKnown() else { return [] }
        let sessions = live.sessions, now = ports.now()
        firstSynced = firstSynced ?? now
        var changed: Set<UUID> = []
        tabs.tabsListed(sessions)
        for run in state.runs where !run.hasEnded {
            if reconcileOperator(run, sessions: sessions) { changed.insert(run.id) }
            let active = state.run(id: run.id)?.state == .active
            for task in state.tasks(inRun: run.id) {
                reconcileWorker(task, active: active, sessions: sessions, now: now)
                if let task = state.task(id: task.id) { reconcileTabs(task, sessions: sessions, now: now) }
            }
        }
        changed.formUnion(applyLimits(now: now, sessions: sessions))
        return changed
    }

    /// Where a run picks up once its operator is back: active once a plan revision is under way. A run
    /// whose last task ended meanwhile is then settled complete by `runChanged`, its Operator told and you notified.
    static func resumedState(of run: OperatorRun) -> OperatorRunState {
        run.planRevision > 0 ? .active : .planning
    }

    /// The operator's tab gone: offline. Back, and with no pause of yours: as it was, and woken.
    private func reconcileOperator(_ run: OperatorRun, sessions: [SessionInfo]) -> Bool {
        let alive = OperatorController.operatorTab(of: run.id, in: sessions) != nil
        let next: OperatorRunState
        switch (run.state, alive) {
        case (.planning, false), (.active, false): next = .operatorOffline
        case (.operatorOffline, true) where run.intent == nil: next = Self.resumedState(of: run)
        default: return false
        }
        workspace.mutate { $0.updateRun(id: run.id) { $0.state = next } }
        if next != .operatorOffline { waker.say("reconnected", to: run.id) }
        return true
    }

    /// A launched task's worker. A tab tagged with the task is its worker: its window opened, which is
    /// recorded — whatever the task's state, so a worker that D10 blocked as busy is adopted, never launched
    /// again. A working task of an active run whose launch never showed a tab or window and named no
    /// conversation, its launch older than `launchAdoptAfter`, with no tab tagged with it, is launched
    /// again as the next attempt, saved first, a minute after its launch task ended — the claim is long before
    /// the window is asked for, and a request that timed out may still open one — or, with no end known, a
    /// minute after this tick pass began. A window that showed and was closed is left for your click
    /// (`OperatorController.reopenWorker`).
    private func reconcileWorker(_ task: TaskItem, active: Bool, sessions: [SessionInfo], now: Date) {
        guard let operated = task.operated, operated.state == .working || operated.state == .blocked,
              let launch = operated.launch else { return }
        if sessions.contains(where: { $0.taskUUID == task.id }) {
            if launch.openedAt == nil { workspace.mutate { $0.updateOperated(task.id) { $0.launch?.openedAt = now } } }
            return
        }
        guard active, operated.state == .working, !operated.takenOver, launch.openedAt == nil, task.windowId == nil,
              task.conversations.isEmpty, !starter.starting.contains(task.id),
              now.timeIntervalSince(max(launch.requestedAt, starter.settledAt[task.id] ?? firstSynced ?? now)) > OperatorTiming.launchAdoptAfter
        else { return }
        let attempt = LaunchAttempt(number: launch.number + 1, requestedAt: now)
        workspace.mutate { $0.updateOperated(task.id) { $0.launch = attempt } }
        guard workspace.flush() else { return }
        lastLaunch = starter.relaunch(task.id, attempt: attempt) ?? lastLaunch
    }

    /// The Operator's extra worker tabs (`open_tab`); a tab tagged with the task and a tab's key is that tab, recorded by
    /// `TabOpener.tabsListed`. One whose request showed no tab, that the daemon did not refuse, its request older than
    /// `launchAdoptAfter`, with no tab tagged for it, is asked for again as its next attempt, saved first, a minute after
    /// its request ended (or, with no end known, after this run of AiTerm's first pass), while its task may have one
    /// (`TabOpener.holds`): the daemon answers with the tab it tagged, if there is one, never a second. A tab that showed
    /// and was closed is not opened again.
    private func reconcileTabs(_ task: TaskItem, sessions: [SessionInfo], now: Date) {
        guard let operated = task.operated, !operated.extraTabs.isEmpty, TabOpener.holds(task, in: state) else { return }
        for tab in operated.extraTabs where tab.sessionId == nil && tab.launch.openedAt == nil && tab.failure == nil {
            let id = TabOpener.ID(task: task.id, key: tab.key)
            guard !tabs.opening.contains(id), !sessions.contains(where: { $0.taskUUID == task.id && $0.tabKey == tab.key }),
                  now.timeIntervalSince(max(tab.launch.requestedAt, tabs.settledAt[id] ?? firstSynced ?? now)) > OperatorTiming.launchAdoptAfter
            else { continue }
            let attempt = LaunchAttempt(number: tab.launch.number + 1, requestedAt: now)
            workspace.mutate { state in
                state.updateOperated(task.id) { operated in
                    if let i = operated.extraTabs.firstIndex(where: { $0.key == tab.key }) { operated.extraTabs[i].launch = attempt }
                }
            }
            guard workspace.flush() else { return }
            lastTab = tabs.relaunch(id, attempt: attempt) ?? lastTab
        }
    }

    /// Spec §8's limits. Each tick adds the time since the last one to every working task of an active
    /// run any of whose worker tabs is busy (`WorkerTab.status`: an extra tab still opening is), once however many
    /// are, and which neither waits on you nor is taken over: at most two intervals' worth, so a Mac asleep is
    /// not work, saved with the task. A worker idle at its prompt is not at work:
    /// its turn ended, and its result waits for review. A task past its runtime, or failed with no retry left, is
    /// blocked with the reason, which the notifier then tells you — never for its runtime while it waits for
    /// acceptance. The runs it blocked a task in.
    private func applyLimits(now: Date, sessions: [SessionInfo]) -> Set<UUID> {
        let interval = ports.reconcileInterval.components
        let step = TimeInterval(interval.seconds) + TimeInterval(interval.attoseconds) / 1e18
        let elapsed = lastCounted.map { min(max(0, now.timeIntervalSince($0)), 2 * step) } ?? 0
        lastCounted = now
        var blocked: [UUID] = []
        workspace.mutate { state in
            for task in state.tasks {
                guard let operated = task.operated, let run = state.run(id: operated.runId), run.state == .active, run.intent == nil
                else { continue }
                let workers = task.workerTabs(in: sessions).map(\.status)
                if elapsed > 0, workers.contains(.working), operated.state == .working, !operated.takenOver,
                   !operated.flags.contains(.waitingOnYou) {
                    state.updateOperated(task.id) { $0.runtimeUsed += elapsed }
                }
                guard let current = state.task(id: task.id)?.operated,
                      let reason = OperatedTransitions.limitReason(for: current,
                                                                   readyForAcceptance: RunStatus.isReadyForAcceptance(
                                                                       current, live: workers[0], extraTabs: Array(workers.dropFirst()))),
                      (try? OperatedTransitions.apply(.block(reason: reason), toTask: task.id, in: &state, by: .aiterm)) != nil
                else { continue }
                blocked.append(task.id)
            }
        }
        var runs: Set<UUID> = []
        for id in blocked {
            if let runId = state.task(id: id)?.operated?.runId { runs.insert(runId) }
        }
        return runs
    }
}
