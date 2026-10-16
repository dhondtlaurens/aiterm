import Foundation
import AiTermCore

/// Starts an operator's queued task (spec §6, §8, §11). Its launch intent — the attempt number — is
/// saved before anything else, so a crash between here and the window is found by the reconciler,
/// which adopts the tab the daemon tagged or, a minute on, launches again. Then the worktree, then
/// the worker: its brief the first prompt, its autonomy the launch flags, its window behind your work.
@MainActor
final class WorkerStarter {
    private let workspace: WorkspaceStore
    private let live: LiveSessions
    private let daemon: @MainActor () -> (any DaemonCommands)?
    private let taskFrame: @MainActor () -> Frame
    private let ports: OperatorPorts
    /// The tasks being started now: a pass that meets one again leaves it be.
    private(set) var starting: Set<UUID> = []
    /// Said when a start blocks its task: you are asked (spec §8).
    var onBlocked: @MainActor (TaskItem, String) -> Void = { _, _ in }

    init(workspace: WorkspaceStore, live: LiveSessions, daemon: @escaping @MainActor () -> (any DaemonCommands)?,
         taskFrame: @escaping @MainActor () -> Frame, ports: OperatorPorts) {
        self.workspace = workspace
        self.live = live
        self.daemon = daemon
        self.taskFrame = taskFrame
        self.ports = ports
    }

    private var state: AppState { workspace.state }

    /// Why a task cannot start now whatever the helper does: it stacks on a code parent that is accepted
    /// but kept no commit to build on. The scheduler counts such a parent satisfied; branching its child from
    /// the default branch instead would silently drop the parent's work.
    private static let noBaseReason = "its code parent has no accepted commit to build on"

    /// Starts the queued task, or nothing: it is already starting, not queued, its run not active, or no
    /// helper is attached to open its window. The claim — `queued → working` with its attempt — is one
    /// change, made and saved before this returns, so the next start pass counts it and a crash finds
    /// it; the worktree and the window follow in the task returned.
    func start(_ id: UUID) -> Task<Void, Never>? {
        guard !starting.contains(id), let task = state.task(id: id), let operated = task.operated, operated.state == .queued,
              state.run(id: operated.runId)?.state == .active, daemon() != nil else { return nil }
        // Before any claim: no attempt, no worktree, nothing started for a task that cannot be based.
        if Self.lacksBase(task, in: state) {
            block(id, reason: "AiTerm couldn’t start it: \(Self.noBaseReason).")
            return nil
        }
        let attempt = LaunchAttempt(number: (operated.launch?.number ?? 0) + 1, requestedAt: ports.now())
        do {
            try workspace.mutate { state in _ = try OperatedTransitions.apply(.start(attempt), toTask: id, in: &state, by: .aiterm) }
        } catch {
            Log.daemon.error("An operator's task could not start: \(String(describing: error), privacy: .public)")
            return nil
        }
        // Not on disk, a crash would leave nothing saying a worker may be running: the claim is taken back,
        // so the slot is free again and the next pass tries the task afresh.
        guard workspace.flush() else {
            release(id, claimedAs: attempt, to: operated)
            return nil
        }
        starting.insert(id)
        return Task {
            defer { starting.remove(id) }
            if operated.retriesUsed > 0, task.hasCheckout, let tab = workerTab(of: id) {
                // A second agent is never started beside a worker that is still there.
                if tab.state == .working {
                    block(id, reason: "AiTerm couldn’t start it: its worker is still busy; stop it or wait.")
                } else {
                    await retryInPlace(task, operated: operated, tab: tab, attempt: attempt, before: operated)
                }
            } else {
                await launch(id, attempt: attempt, before: operated)
            }
        }
    }

    /// Opens the task's worker as `attempt`: its worktree made or adopted, then its window, in the
    /// background. A failure that leaves the window's fate unknown — a timeout, the helper or iTerm2
    /// gone — is left for the reconciler; any other blocks the task with the reason.
    /// `before` is the task as it stood before `attempt` claimed it: what a claim that no longer holds
    /// goes back to. The reconciler's relaunch passes none: its claim was made before, and stays.
    func launch(_ id: UUID, attempt: LaunchAttempt, before: OperatedTask? = nil) async {
        guard let task = state.task(id: id), let operated = task.operated, let run = state.run(id: operated.runId),
              let project = state.project(id: task.projectId), let daemon = daemon() else { return }
        let git = ports.git, autonomy = run.persona.autonomy
        do {
            let start = try await startPoint(of: id, in: project)
            let reserved = state.reservedWorktreeSlugs(projectId: project.id)
            let made = try await BackgroundWork.run { try TaskCreator.checkOutWorker(task, project: project, start: start, reserved: reserved, git: git) }
            workspace.mutate { state in
                guard let i = state.tasks.firstIndex(where: { $0.id == id }) else { return }
                state.tasks[i].worktreePath = made.task.worktreePath
                state.tasks[i].baseBranch = made.task.baseBranch
            }
            let prompt = Self.prompt(for: task, operated: operated), worktree = made.task.worktreePath
            // The operation's autonomy as the worker's launch flags (part C), its brief the first prompt.
            let command = try await BackgroundWork.run {
                try AgentCommand.build(agent: task.agent, model: task.model, reasoning: task.reasoning, prompt: prompt,
                                       worktreePath: worktree, git: git, operated: autonomy)
            }
            // Awaits have passed: the task may have been stopped, taken over or blocked, or its run paused.
            guard claimHolds(id, attempt) else {
                release(id, claimedAs: attempt, to: before)
                return
            }
            let window = try await daemon.createTaskWindow(taskId: id.uuidString, cwd: worktree, title: task.branch, agentCommand: command,
                                                           frame: taskFrame(), background: true)
            recordWindow(window, of: id)
        } catch let error as DaemonError where [.timeout, .disconnected, .itermUnavailable].contains(error.code) {
            Log.daemon.info("An operator's worker window may still open; the run reconciler looks again: \(error.message, privacy: .public)")
        } catch {
            block(id, reason: "AiTerm couldn’t start it: \(error.localizedDescription)")
        }
    }

    /// The worker's window, and that its launch showed one: from now on it comes back only on your
    /// click (`OperatorController.reopenWorker`), never launched again.
    func recordWindow(_ window: String, of id: UUID) {
        let now = ports.now()
        workspace.mutate { state in
            guard let i = state.tasks.firstIndex(where: { $0.id == id }) else { return }
            state.tasks[i].windowId = window
            if state.tasks[i].operated?.launch?.openedAt == nil { state.tasks[i].operated?.launch?.openedAt = now }
        }
    }

    /// The worker's first prompt: its brief, and after a failure what failed (spec §6 `retry_task`).
    static func prompt(for task: TaskItem, operated: OperatedTask) -> String {
        guard operated.retriesUsed > 0, let failure = operated.lastFailure else { return operated.brief }
        return "The last attempt failed: \(failure). Try again from the worktree as it is.\n\n\(operated.brief)"
    }

    /// Whether the task has a code parent and no accepted commit of its parent's to start from.
    private static func lacksBase(_ task: TaskItem, in state: AppState) -> Bool {
        guard task.operated?.dependsOn.contains(where: { $0.kind == .code }) == true else { return false }
        return RunScheduler.baseCommit(for: task.id, in: state)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    /// Where the worktree branches from: a code parent's accepted commit (`RunScheduler.baseCommit`), or
    /// the project's default branch. A code dependent never falls back to the default branch.
    private func startPoint(of id: UUID, in project: Project) async throws -> String {
        if let task = state.task(id: id) {
            if Self.lacksBase(task, in: state) { throw ActionUnavailable(Self.noBaseReason) }
            if let commit = RunScheduler.baseCommit(for: id, in: state) { return commit.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let git = ports.git, path = project.path
        return await BackgroundWork.run { Repository(path, git: git).defaultBranch() }
    }

    /// A retry with its worker alive and idle: the same session is told to try again. Refused — a
    /// prompt open, you typing — it is not idle after all, and a second worker is never started beside it.
    private func retryInPlace(_ task: TaskItem, operated: OperatedTask, tab: SessionInfo, attempt: LaunchAttempt, before: OperatedTask) async {
        guard let daemon = daemon() else { return }
        guard claimHolds(task.id, attempt) else {
            release(task.id, claimedAs: attempt, to: before)
            return
        }
        let delivery = try? await daemon.deliver(sessionId: tab.sessionId, text: Self.prompt(for: task, operated: operated),
                                                 ownership: operated.ownership, wake: false, worktree: task.worktreePath)
        if delivery == nil || delivery?.result == .refused {
            block(task.id, reason: "Its worker couldn’t take the retry: \(delivery?.reason ?? "the helper didn’t answer").")
        } else {
            // Its worker was shown already: never launched again.
            recordWindow(tab.windowId, of: task.id)
        }
    }

    /// Whether the claim `attempt` made still holds: the task is working on it, not taken over, and its
    /// run is active.
    private func claimHolds(_ id: UUID, _ attempt: LaunchAttempt) -> Bool {
        guard let operated = state.task(id: id)?.operated, operated.state == .working, operated.launch == attempt,
              !operated.takenOver else { return false }
        return state.run(id: operated.runId)?.state == .active
    }

    /// Takes a claim back: the task as it was before `attempt`, so it queues again and its slot is free. Only
    /// while it is still working on that attempt — a task stopped, blocked or changed since is left as it is.
    private func release(_ id: UUID, claimedAs attempt: LaunchAttempt, to before: OperatedTask?) {
        // A relaunch has no earlier record: its launch was claimed before, and stays.
        guard let before else { return }
        workspace.mutate { state in
            guard let i = state.tasks.firstIndex(where: { $0.id == id }), let operated = state.tasks[i].operated,
                  operated.state == .working, operated.launch == attempt else { return }
            state.tasks[i].operated?.state = before.state
            state.tasks[i].operated?.launch = before.launch
            state.tasks[i].operated?.blockedReason = before.blockedReason
        }
    }

    private func workerTab(of id: UUID) -> SessionInfo? {
        live.sessions.filter { $0.taskUUID == id && $0.agent.agentKind != nil }.min { $0.tabIndex < $1.tabIndex }
    }

    /// Blocks the task and asks you — only when the block took: a task already stopped or changed is left
    /// as it is, and you are not told of a block that did not happen.
    private func block(_ id: UUID, reason: String) {
        let before = state.task(id: id)?.operated
        do {
            try workspace.mutate { state in _ = try OperatedTransitions.apply(.block(reason: reason), toTask: id, in: &state, by: .aiterm) }
        } catch {
            Log.daemon.error("An operator's task could not be blocked: \(String(describing: error), privacy: .public)")
            return
        }
        if let task = state.task(id: id), task.operated != before { onBlocked(task, reason) }
    }
}
