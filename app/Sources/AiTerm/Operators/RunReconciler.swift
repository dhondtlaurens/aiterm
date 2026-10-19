import Foundation
import AiTermCore

/// Looks at the real tabs and says what it finds (spec §7.3, §8, §11): an operator whose tab has gone
/// takes its operation offline, and one back brings it back — never a pause or stop of yours; a worker
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
    private let waker: OperatorWaker
    private let notifier: OperatorNotifier
    private let ports: OperatorPorts
    /// Whether a connected snapshot has come since the helper attached: until then, a tab not listed
    /// is not a tab gone.
    var synced = false
    /// The latest relaunch, for a test to await.
    private(set) var lastLaunch: Task<Void, Never>?
    /// When the last tick counted runtime; nil until the first tick after AiTerm starts, which only
    /// sets it, so the time AiTerm was not running is not counted.
    private var lastCounted: Date?
    /// Whether the open questions have been held again since AiTerm started: the notifier keeps what it
    /// holds in memory only.
    private var reheld = false
    /// When the first synced tick of this run of AiTerm came: a launch it knows no end of (it began before
    /// AiTerm started) is counted a minute from here at the soonest, so a slow iTerm2 has listed its window.
    private var firstSynced: Date?

    init(workspace: WorkspaceStore, live: LiveSessions, starter: WorkerStarter, waker: OperatorWaker, notifier: OperatorNotifier,
         ports: OperatorPorts) {
        self.workspace = workspace
        self.live = live
        self.starter = starter
        self.waker = waker
        self.notifier = notifier
        self.ports = ports
    }

    private var state: AppState { workspace.state }

    /// One pass. The runs whose state it changed or in which it blocked a task, for their scheduling and completion.
    @discardableResult
    func tick() -> Set<UUID> {
        guard synced else { return [] }
        let sessions = live.sessions, now = ports.now()
        firstSynced = firstSynced ?? now
        holdOpenQuestionsAgain()
        var changed: Set<UUID> = []
        for run in state.runs where run.state != .stopped && run.intent != .stopped {
            if reconcileOperator(run, sessions: sessions) { changed.insert(run.id) }
            let active = state.run(id: run.id)?.state == .active
            for task in state.tasks(inRun: run.id) {
                reconcileWorker(task, active: active, sessions: sessions, now: now)
            }
        }
        changed.formUnion(applyLimits(now: now, sessions: sessions))
        for run in state.runs where run.state != .stopped {
            notifier.releaseHeld(in: run, otherWorkCanProceed: state.otherWorkCanProceed(in: run))
        }
        return changed
    }

    /// Where a run picks up once its operator is back: active once a plan revision is under way. A run
    /// whose last task ended meanwhile is then settled complete by `runChanged`, its Operator told and you notified.
    static func resumedState(of run: OperatorRun) -> OperatorRunState {
        run.planRevision > 0 ? .active : .planning
    }

    /// The first pass after AiTerm starts: each open question of the operator — a worker waiting on you
    /// for an answer — is held again, since what the notifier held was lost with the last run. A worker's
    /// prompt is not: it was notified at once, and the overview and its row still show it.
    private func holdOpenQuestionsAgain() {
        guard !reheld else { return }
        reheld = true
        for run in state.runs where run.state != .stopped && run.intent != .stopped {
            for question in run.questions where question.resolution == nil && !question.id.hasPrefix("prompt-") {
                notifier.rehold(question, in: run)
            }
        }
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

    /// Spec §8's limits. Each tick adds the time since the last one to every working task of an active
    /// run that has a worker tab and neither waits on you nor is taken over — at most two intervals'
    /// worth, so a Mac asleep is not work — saved with the task. A task past its runtime, or failed with no retry left, is
    /// blocked with the reason and you are asked. The runs it blocked a task in.
    private func applyLimits(now: Date, sessions: [SessionInfo]) -> Set<UUID> {
        let interval = ports.reconcileInterval.components
        let step = TimeInterval(interval.seconds) + TimeInterval(interval.attoseconds) / 1e18
        let elapsed = lastCounted.map { min(max(0, now.timeIntervalSince($0)), 2 * step) } ?? 0
        lastCounted = now
        var blocked: [(task: UUID, reason: String)] = []
        workspace.mutate { state in
            for task in state.tasks {
                guard let operated = task.operated, let run = state.run(id: operated.runId), run.state == .active, run.intent == nil
                else { continue }
                let worked = sessions.contains { $0.taskUUID == task.id && $0.agent.agentKind != nil }
                if elapsed > 0, worked, operated.state == .working, !operated.takenOver, !operated.flags.contains(.waitingOnYou) {
                    state.updateOperated(task.id) { $0.runtimeUsed += elapsed }
                }
                guard let current = state.task(id: task.id)?.operated,
                      let reason = OperatedTransitions.limitReason(for: current),
                      (try? OperatedTransitions.apply(.block(reason: reason), toTask: task.id, in: &state, by: .aiterm)) != nil
                else { continue }
                blocked.append((task.id, reason))
            }
        }
        var runs: Set<UUID> = []
        for (id, reason) in blocked {
            guard let task = state.task(id: id), let runId = task.operated?.runId, let run = state.run(id: runId) else { continue }
            notifier.taskBlocked(task, reason: reason, in: run)
            runs.insert(runId)
        }
        return runs
    }
}
