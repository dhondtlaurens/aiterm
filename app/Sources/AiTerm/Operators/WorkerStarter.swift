import Foundation
import AiTermCore

/// Starts an operator's queued task (spec §6, §8, §11). Its launch intent — the attempt number — is
/// saved before anything else, so a crash between here and the window is found by the reconciler,
/// which adopts the tab the daemon tagged or, a minute on, launches again. Then the worktree, then
/// the worker: its brief the first prompt, the Operator's worker flags, its window behind your work.
@MainActor
final class WorkerStarter {
    private let workspace: WorkspaceStore
    private let live: LiveSessions
    private let daemon: @MainActor () -> (any DaemonCommands)?
    private let taskFrame: @MainActor () -> Frame
    private let ports: OperatorPorts
    private let workflow: TaskWorkflow
    private var isStopped = false
    /// The tasks being started now: a pass that meets one again leaves it be.
    private(set) var starting: Set<UUID> = []
    /// When each task's last launch task in this run of AiTerm ended: a launch that ended without a
    /// window (a timeout) may still open one, so the reconciler counts its minute from here, not from the claim.
    private(set) var settledAt: [UUID: Date] = [:]
    /// Each claim made and not yet launched or released: the task as it stood before it, and the attempt
    /// that claimed it — what a claim that does not hold goes back to, and the failure a retry tells of.
    private var claims: [UUID: Claim] = [:]
    private struct Claim {
        let before: OperatedTask
        let attempt: LaunchAttempt
    }
    /// When a launch or a reopen last asked iTerm2 for each task's window, or ended not knowing whether one
    /// opens, until iTerm2 lists a worker tab tagged with the task (`isFirstWorkerTab`), not the shell the agent
    /// command is still being typed into. A claim in that gap — the task failed and was retried meanwhile —
    /// would find no worker to retry in and launch again, so none is made for `launchAdoptAfter`, the time a
    /// slow iTerm2 has to list it. Past that, the claim goes ahead: with a worker listed by then the retry goes
    /// to it in place; with none, it is launched, and a window still tagged with the task is the one the
    /// helper hands back — never a second — though its shell is not told of the retry.
    private var unlisted: [UUID: Date] = [:]
    /// When each task's worker window was last reopened on your click: a click in the gap before iTerm2
    /// lists its tab (up to `launchAdoptAfter`) opens no second window.
    private var reopenedAt: [UUID: Date] = [:]
    /// Said when a start blocks its task: you are asked (spec §8).
    var onBlocked: @MainActor (TaskItem) -> Void = { _ in }
    var onUncertain: @MainActor (TaskItem) -> Void = { _ in }
    /// Told when a start or a reopen begins and ends: the task's line says `Operator starting it` or
    /// `reopening its window` meanwhile (the controller's `acting`).
    var onActing: @MainActor (OperatorActivity, Bool) -> Void = { _, _ in }

    init(workspace: WorkspaceStore, live: LiveSessions, daemon: @escaping @MainActor () -> (any DaemonCommands)?,
         taskFrame: @escaping @MainActor () -> Frame, ports: OperatorPorts) {
        self.workspace = workspace
        self.live = live
        self.daemon = daemon
        self.taskFrame = taskFrame
        self.ports = ports
        self.workflow = TaskWorkflow(git: ports.git)
    }

    private var state: AppState { workspace.state }

    func start() { isStopped = false }
    func stop() { isStopped = true }

    /// Why a task cannot start now whatever the helper does: it stacks on a code parent that is accepted
    /// but kept no commit to build on. The scheduler counts such a parent satisfied; branching its child from
    /// the default branch instead would silently drop the parent's work.
    private static let noBaseReason = "its code parent has no accepted commit to build on"

    /// What may start now, claimed on the workspace in one change (`RunScheduler.claim`) and each claim
    /// marked starting at once, so no pass claims it again and no reconcile pass reopens or relaunches it
    /// before `launchClaimed` has run. A task already starting — a launch, a relaunch, a reopen — is left
    /// out, and so is one whose window was just asked for and is not listed yet (`unlisted`); one whose
    /// code parent kept no commit is blocked first. The caller saves the claims before launching any
    /// (spec §11), and releases them if it cannot.
    func claimReady() -> [UUID] {
        guard !isStopped else { return [] }
        let busy = busy()
        blockUnbased(excluding: busy)
        let before = state, now = ports.now()
        let claimed = workspace.mutate { RunScheduler.claim(in: &$0, now: now, excluding: busy) }
        for id in claimed {
            starting.insert(id)
            if let operated = before.task(id: id)?.operated, let attempt = state.task(id: id)?.operated?.launch {
                claims[id] = Claim(before: operated, attempt: attempt)
            }
        }
        return claimed
    }

    /// Claims that will not be launched now — the workspace did not save them: each is taken back, so
    /// the task queues again, and the next pass tries it afresh.
    func release(_ ids: [UUID]) {
        for id in ids {
            starting.remove(id)
            guard let claim = claims.removeValue(forKey: id) else { continue }
            release(id, claimedAs: claim.attempt, to: claim.before)
        }
    }

    /// Opens a claimed task's worker as `attempt`, its claim saved: a retry whose worker is still there is
    /// told to try again in its own tab if it is idle, and blocked with the reason if it is busy — a second
    /// worker is never started beside it; anything else is launched, worktree then a window behind your
    /// work. A claim that no longer holds is taken back. Out of `starting`, its end time kept, when done.
    func launchClaimed(_ id: UUID, attempt: LaunchAttempt) async {
        defer {
            claims[id] = nil
            settle(id)
        }
        guard let claim = claims[id], claim.attempt == attempt, let task = state.task(id: id) else {
            // Only `claimReady`'s claims are launched here; the reconciler relaunches this one a minute on.
            Log.daemon.error("An operator's task was launched with no claim of attempt \(attempt.number, privacy: .public); nothing opened")
            return
        }
        let before = claim.before
        guard claimHolds(id, attempt) else {
            release(id, claimedAs: attempt, to: before)
            return
        }
        if before.retriesUsed > 0, task.hasCheckout, let tab = workerTab(of: id) {
            if tab.state == .working {
                block(id, reason: "AiTerm couldn’t start it: its worker is still busy; stop it or wait.")
            } else {
                await retryInPlace(task, operated: before, tab: tab, attempt: attempt, before: before)
            }
        } else {
            await launch(id, attempt: attempt, before: before)
        }
    }

    /// Before any claim, each task the scheduler would start whose code parent kept no commit is blocked:
    /// no attempt, no worktree, nothing started for a task that cannot be based. Its block's notice may
    /// run a start pass of its own (`onBlocked`), which claims from the state as it is then; the caller's
    /// claim, made after, counts those claims.
    /// The tasks no claim may take now: those starting, and those whose window was asked for within
    /// `launchAdoptAfter` and is not listed yet. Older ones are forgotten — that window never came.
    private func busy() -> Set<UUID> {
        let now = ports.now()
        unlisted = unlisted.filter { now.timeIntervalSince($0.value) < OperatorTiming.launchAdoptAfter }
        return starting.union(unlisted.keys)
    }

    private func blockUnbased(excluding busy: Set<UUID>) {
        var seen: Set<UUID> = []
        while let id = RunScheduler.startable(in: state, excluding: busy).first(where: { id in
            guard !seen.contains(id), let task = state.task(id: id) else { return false }
            return Self.lacksBase(task, in: state)
        }) {
            seen.insert(id)
            block(id, reason: "AiTerm couldn’t start it: \(Self.noBaseReason).")
        }
    }

    /// Opens the task's worker as `attempt`: its worktree made or adopted, then its window, in the
    /// background. A failure that leaves the window's fate unknown — a timeout, the helper or iTerm2
    /// gone — is left for the reconciler; any other blocks the task with the reason.
    /// `before` is the task as it stood before `attempt` claimed it: what a claim that no longer holds
    /// goes back to. The reconciler's relaunch passes none: its claim was made before, and stays.
    func launch(_ id: UUID, attempt: LaunchAttempt, before: OperatedTask? = nil) async {
        guard !isStopped, let task = state.task(id: id), let operated = task.operated, state.run(id: operated.runId) != nil,
              let project = state.project(id: task.projectId), let daemon = daemon() else { return }
        let activity = OperatorActivity(run: operated.runId, task: id, act: .starting)
        onActing(activity, true)
        defer { onActing(activity, false) }
        let git = ports.git
        do {
            let start = try await startPoint(of: id, in: project)
            let reserved = state.reservedWorktreeSlugs(projectId: project.id)
            let (made, baseline) = try await workflow.checkOutWorker(task, project: project, start: start, reserved: reserved)
            workspace.mutate { state in
                guard let i = state.tasks.firstIndex(where: { $0.id == id }) else { return }
                state.tasks[i].worktreePath = made.task.worktreePath
                state.tasks[i].baseBranch = made.task.baseBranch
                if state.tasks[i].operated?.diffBaseSHA == nil { state.tasks[i].operated?.diffBaseSHA = baseline }
            }
            let prompt = Self.prompt(for: task, operated: operated), worktree = made.task.worktreePath
            let choice = launchChoice(for: task, operated: operated, attempt: attempt)
            // The Operator's worker flags, its brief the first prompt.
            let command = try await BackgroundWork.run {
                try AgentCommand.build(agent: choice.agent, model: choice.model, reasoning: choice.reasoning, prompt: prompt,
                                       worktreePath: worktree, git: git, operated: true)
            }
            // Awaits have passed: the task may have been stopped, taken over or blocked, or its run paused.
            guard claimHolds(id, attempt) else {
                release(id, claimedAs: attempt, to: before)
                return
            }
            // A relaunch: a reply lost to a timeout may have left the window it asked for. Found by its tag
            // now, it is the worker — never a second one beside it.
            if before == nil, let orphan = live.sessions.first(where: { $0.taskUUID == id }) {
                recordWindow(orphan.windowId, of: id)
                return
            }
            if let switched = choice.switchedFrom { recordSwitch(of: id, to: choice, from: switched) }
            let window = try await daemon.createTaskWindow(taskId: id.uuidString, cwd: worktree, title: task.branch, agentCommand: command,
                                                           frame: taskFrame(), background: true)
            unlisted[id] = ports.now()
            recordWindow(window, of: id)
        } catch let error as DaemonError where [.timeout, .disconnected, .itermUnavailable].contains(error.code) {
            unlisted[id] = ports.now()
            Log.daemon.info("An operator's worker window may still open; the run reconciler looks again: \(error.message, privacy: .public)")
        } catch {
            block(id, reason: "AiTerm couldn’t start it: \(error.localizedDescription)")
        }
    }

    /// What a task launches with. Its planned agent and model, unless this is its first launch, it is not
    /// pinned and its agent's weekly use is near the limit (`ModelChoice.launchAgent`): then the other agent
    /// and its first allowed row. `switchedFrom` names the planned agent.
    /// A relaunch or a retry keeps the agent it started on.
    private func launchChoice(for task: TaskItem, operated: OperatedTask, attempt: LaunchAttempt) -> LaunchChoice {
        let keep = LaunchChoice(agent: task.agent, model: task.model, reasoning: task.reasoning, switchedFrom: nil, percent: 0)
        guard attempt.number == 1, operated.retriesUsed == 0 else { return keep }
        let weekly = ports.weeklyUsage?() ?? [:], installed = ports.installedAgents?() ?? Set(AgentKind.allCases)
        guard let run = state.run(id: operated.runId) else { return keep }
        let planned = AgentChoice(agent: task.agent, model: task.model, reasoning: task.reasoning)
        let row = ModelChoice.launchChoice(planned: planned, pinned: operated.agentPinned, weekly: weekly,
                                           installed: installed, rows: run.agents)
        guard row.agent != task.agent else { return keep }
        return LaunchChoice(agent: row.agent, model: row.model, reasoning: row.reasoning, switchedFrom: task.agent,
                            percent: weekly[task.agent] ?? 0)
    }

    /// What a task launches with (`launchChoice`): `switchedFrom` is the planned agent when it starts on the other, and
    /// `percent` that agent's weekly use, which is why.
    private struct LaunchChoice {
        let agent: AgentKind, model: String, reasoning: String?, switchedFrom: AgentKind?, percent: Int
    }

    /// The switch, saved before the window opens: the task's agent and model, why, and one line in the run's
    /// decisions, keyed by the task so a launch that runs again logs nothing twice.
    private func recordSwitch(of id: UUID, to choice: LaunchChoice, from planned: AgentKind) {
        guard let task = state.task(id: id), let runId = task.operated?.runId else { return }
        let why = "\(SidebarModel.agentName(planned))’s weekly limit is at \(choice.percent) %."
        let text = "Started \(task.title) on \(SidebarModel.agentName(choice.agent)): \(why)"
        let key = "switch-\(id.uuidString)", now = ports.now()
        workspace.mutate { state in
            guard let i = state.tasks.firstIndex(where: { $0.id == id }) else { return }
            state.tasks[i].agent = choice.agent
            state.tasks[i].model = choice.model
            state.tasks[i].reasoning = choice.reasoning
            state.tasks[i].operated?.modelReason = text
            state.updateRun(id: runId) { run in
                if !run.decisions.contains(where: { $0.key == key }) {
                    run.decisions.append(OperatorDecision(key: key, text: "Started \(task.title) on \(SidebarModel.agentName(choice.agent))",
                                                          task: id, at: now, why: why))
                }
            }
        }
    }

    /// A launch that showed no tab, tried again as `attempt` — saved by the caller first.
    func relaunch(_ id: UUID, attempt: LaunchAttempt) -> Task<Void, Never>? {
        guard !isStopped, !starting.contains(id) else { return nil }
        starting.insert(id)
        return Task {
            defer { settle(id) }
            await launch(id, attempt: attempt)
        }
    }

    /// A worker's window you closed, brought back on your click (`OperatorController.reopenWorker`):
    /// reopened behind your work, its conversation resumed under the broadcast's flags — never a second
    /// worker. Nil when it is starting, has a tab, was reopened a moment ago and its tab is not listed yet, has no worktree
    /// or no conversation to resume, or no helper is there. Only the first worker's conversation resumes
    /// (`TaskItem.firstWorkerConversation`): an extra tab the Operator added (`open_tab`) is never opened again.
    func reopen(_ id: UUID) -> Task<Void, Never>? {
        guard !isStopped else { return nil }
        if let at = reopenedAt[id], ports.now().timeIntervalSince(at) < OperatorTiming.launchAdoptAfter { return nil }
        guard !starting.contains(id), !live.sessions.contains(where: { $0.taskUUID == id }), let task = state.task(id: id),
              task.hasCheckout, let operated = task.operated, state.run(id: operated.runId) != nil, let conversation = task.firstWorkerConversation,
              let daemon = daemon() else { return nil }
        starting.insert(id)
        let reopening = OperatorActivity(run: operated.runId, task: id, act: .reopeningItsWindow)
        onActing(reopening, true)
        return Task {
            defer {
                starting.remove(id)
                onActing(reopening, false)
            }
            do {
                let command = AgentCommand.resumeWorker(agent: task.agent, conversation: conversation.id, model: task.model,
                                                        reasoning: task.reasoning)
                let window = try await daemon.createTaskWindow(taskId: id.uuidString, cwd: task.worktreePath, title: task.branch,
                                                               agentCommand: command, frame: taskFrame(), background: true)
                // Left on the row, so a click raises it.
                recordWindow(window, of: id)
                reopenedAt[id] = ports.now()
                unlisted[id] = ports.now()
            } catch {
                Log.daemon.error("An operator's worker window could not reopen: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The tabs iTerm2 lists now: a reopened worker whose tab has come needs no more waiting, and a task
    /// held back from claims until its worker was listed — a tab running its agent, as `workerTab` finds it —
    /// may be claimed. Whether one was: a start pass may have something new to start.
    @discardableResult
    func tabsListed(_ sessions: [SessionInfo]) -> Bool {
        let tagged = Set(sessions.compactMap(\.taskUUID))
        for id in reopenedAt.keys where tagged.contains(id) { reopenedAt[id] = nil }
        for id in tagged { checkWorker(id, sessions: sessions) }
        let workers = Set(sessions.filter(Self.isFirstWorkerTab).compactMap(\.taskUUID))
        let listed = unlisted.keys.filter(workers.contains)
        for id in listed { unlisted[id] = nil }
        return !listed.isEmpty
    }

    private func settle(_ id: UUID) {
        starting.remove(id)
        settledAt[id] = ports.now()
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
        checkWorker(id, sessions: live.sessions)
    }

    /// A tagged shell confirms a window, not an agent. Keep that uncertainty visible until an agent appears.
    private func checkWorker(_ id: UUID, sessions: [SessionInfo]) {
        guard let task = state.task(id: id), let operated = task.operated, operated.launch != nil,
              [.working, .blocked].contains(operated.state) else { return }
        let tabs = sessions.filter { $0.taskUUID == id }
        guard !tabs.isEmpty else { return }
        if tabs.contains(where: Self.isWorkerTab) {
            if operated.flags.contains(.uncertain) { workspace.mutate { $0.updateOperated(id) { $0.flags.remove(.uncertain) } } }
        } else if !operated.flags.contains(.uncertain) {
            workspace.mutate { $0.updateOperated(id) { $0.flags.insert(.uncertain) } }
            onUncertain(state.task(id: id) ?? task)
        }
    }

    /// The worker's first prompt: AiTerm's own line on where it works (`worktreeLine`), then its brief, and
    /// after a failure what failed (spec §6 `retry_task`).
    static func prompt(for task: TaskItem, operated: OperatedTask) -> String {
        let brief = operated.retriesUsed > 0 && operated.lastFailure != nil
            ? "The last attempt failed: \(operated.lastFailure ?? ""). Try again from the worktree as it is.\n\n\(operated.brief)"
            : operated.brief
        return worktreeLine(branch: task.branch) + "\n\n" + brief
    }

    /// The fixed line every worker's first prompt starts with, from AiTerm and never the Operator: AiTerm reads
    /// the task branch alone, so work committed anywhere else goes unseen (`BranchWatch` flags it).
    /// Inventories stay in the conversation: repository files can expose personal paths and addresses. And no
    /// settings command in a live session: Claude Code saves a /model or /effort as the person's default.
    nonisolated static func worktreeLine(branch: String) -> String {
        "[AiTerm] You are already in this task's worktree, on branch \(branch). Commit only here, on \(branch). "
            + "Do not create another worktree or branch. Inventories, audits and lists go in your final message, "
            + "never in a new file in the repository. "
            + "Never type /model, /effort or /config into a live agent session: they save the person's defaults. "
            + "To try a model or effort, use launch flags or a scratch CLAUDE_CONFIG_DIR. "
            + "Keep each background command's handle/PID, log and exit status. Queued tests are not stalled. "
            + "Finish when your command exits; do not poll other test processes."
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
        let activity = OperatorActivity(run: operated.runId, task: task.id, act: .starting)
        onActing(activity, true)
        defer { onActing(activity, false) }
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
        guard !isStopped, let operated = state.task(id: id)?.operated, operated.state == .working, operated.launch == attempt,
              !operated.takenOver else { return false }
        return state.run(id: operated.runId)?.state == .active
    }

    /// Takes a claim back: the task as it was before `attempt`, so it queues again. Only
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

    /// The task's first worker (`TaskItem.firstWorker`): the one a retry goes to.
    private func workerTab(of id: UUID) -> SessionInfo? { state.task(id: id)?.firstWorker(in: live.sessions) }

    /// A tab running an agent: a worker. A new worker's tab is listed first as the shell its command is typed into.
    static func isWorkerTab(_ tab: SessionInfo) -> Bool { tab.agent.agentKind != nil }

    /// A tab running an agent that is none of the Operator's extra tabs (`open_tab`): the task's first worker, as
    /// `TaskItem.firstWorker` finds it.
    static func isFirstWorkerTab(_ tab: SessionInfo) -> Bool { isWorkerTab(tab) && tab.tabKey == nil }

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
        if let task = state.task(id: id), task.operated != before { onBlocked(task) }
    }
}
