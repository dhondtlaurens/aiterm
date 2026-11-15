import Foundation
import AiTermCore

/// Persist stage and launch intents before effects. A stage never reaches a worker mid-turn and
/// every await is followed by an ownership check, so Take Over invalidates late completions.
@MainActor final class StageRunner {
    struct Ports {
        var workerIsWorking: (UUID) -> Bool
        var prepare: (TaskItem, Signal) async throws -> TaskItem
        var launch: (TaskItem, String) async throws -> String
        var restore: (TaskItem) async throws -> TaskItem
    }
    private let workspace: WorkspaceStore
    private let journal: SignalJournal
    private let now: () -> Date
    private let ports: Ports
    private var running: Set<UUID> = []
    private var isStopped = false
    private var generation = UUID()
    func start() { isStopped = false }
    func stop() { isStopped = true; generation = UUID() }
    func isRunning(_ id: UUID) -> Bool { running.contains(id) }
    var changed: (UUID, String) -> Void = { _, _ in }
    init(workspace: WorkspaceStore, journal: SignalJournal, now: @escaping () -> Date, ports: Ports) {
        self.workspace = workspace; self.journal = journal; self.now = now; self.ports = ports
    }
    func run(_ id: UUID) async {
        guard !isStopped, workspace.canChangeWorkspace, workspace.state.operatorSession?.paused != true, !running.contains(id), !ports.workerIsWorking(id),
              let initial = workspace.state.signalItem(id: id), let claim = SignalClaim(initial),
              let record = initial.signalTask, record.phase == .launching,
              let signal = record.configuration ?? workspace.state.signal(id: record.signal), signal.isRunnable else { return }
        let launchGeneration = generation
        running.insert(id); defer { running.remove(id) }
        do {
            if workspace.state.archived(id: id) != nil {
                let restored = try await ports.restore(initial)
                guard holds(claim, generation: launchGeneration) else { return }
                workspace.mutate { state in
                    state.moveFromArchive(id: id)
                    state.updateSignalItem(id) { $0.worktreePath = restored.worktreePath }
                }
            }
            guard holds(claim, generation: launchGeneration), !ports.workerIsWorking(id) else { return }
            let attempt = LaunchAttempt(number: (record.launch?.number ?? 0) + 1, requestedAt: now(), workerPending: true)
            workspace.mutate { state in
                state.updateSignalItem(id) { task in
                    task.firstPrompt = task.signalTask?.prompt ?? signal.work.prompt
                    task.signalTask?.launch = attempt
                    task.signalTask?.currentAct = "starting its worker"
                }
            }
            guard workspace.flush() else { return }
            try await journal.append(.ours("Starting stage \(record.stage) from \(signal.name)."), task: id)
            guard holds(claim, generation: launchGeneration), let before = workspace.state.task(id: id) else { return }
            if !before.hasCheckout {
                let prepared = try await ports.prepare(before, signal)
                guard holds(claim, generation: launchGeneration) else { return }
                workspace.mutate { $0.updateSignalItem(id) { task in
                    task.worktreePath = prepared.worktreePath; task.branch = prepared.branch; task.baseBranch = prepared.baseBranch
                } }
                guard workspace.flush() else { return }
            }
            guard holds(claim, generation: launchGeneration), !ports.workerIsWorking(id), let task = workspace.state.task(id: id) else { return }
            let prompt = WorkerStarter.worktreeLine(branch: task.branch) + "\n\n" + (task.firstPrompt ?? signal.work.prompt)
            let window = try await ports.launch(task, prompt)
            guard holds(claim, generation: launchGeneration) else { return }
            let at = now()
            try workspace.mutate { state in
                try state.updateSignalItem(id) { task in
                    guard let record = task.signalTask else { return }
                    task.signalTask = try SignalTransitions.apply(.workerStarted, to: record, at: at)
                    task.signalTask?.launch?.openedAt = at
                    task.signalTask?.currentAct = nil; task.windowId = window
                }
            }
            workspace.flush()
            changed(id, "Its stage started.")
        } catch {
            guard !Task.isCancelled, !isStopped, generation == launchGeneration, claim.holds(in: workspace.state) else { return }
            workspace.mutate { $0.updateSignalTask(id) { record in
                record.phase = .blocked; record.blockedReason = OperationIssue.reason(of: error); record.currentAct = nil
            } }
            workspace.flush()
            changed(id, "Its worker could not start.")
        }
    }
    func resume(_ id: UUID, project: UUID? = nil, agent: AgentChoice? = nil) async throws {
        guard !isStopped, workspace.canChangeWorkspace, workspace.state.operatorSession?.paused != true,
              let task = workspace.state.signalItem(id: id), let record = task.signalTask, !record.takenOver,
              record.phase == .blocked, let signal = record.configuration ?? workspace.state.signal(id: record.signal), signal.isRunnable else {
            throw ActionUnavailable("Only a blocked task of the Operator can be resumed.")
        }
        if let candidates = record.candidateProjects, candidates.count > 1 {
            guard let project, candidates.contains(project), workspace.state.project(id: project) != nil else {
                throw ActionUnavailable("Choose one of this ticket's linked projects.")
            }
        } else if let project, project != task.projectId { throw ActionUnavailable("This task already belongs to another project.") }
        let choice = agent ?? (signal.agents.count == 1 ? signal.agents.first : nil)
        guard let choice, signal.agents.contains(choice), AgentCommand.operatedAgents.contains(choice.agent), !choice.model.isEmpty else {
            throw ActionUnavailable("Choose one of this signal's permitted agents and models.")
        }
        if let project, project != task.projectId, task.hasCheckout { throw ActionUnavailable("A task with a checkout cannot move repositories.") }
        let next = try SignalTransitions.apply(.resume, to: record, at: now())
        workspace.mutate { $0.updateSignalItem(id) { task in
            task.signalTask = next; task.signalTask?.candidateProjects = nil
            if let project { task.projectId = project }
            task.agent = choice.agent; task.model = choice.model; task.reasoning = choice.reasoning
        } }
        guard workspace.flush() else { throw ActionUnavailable("The resume intent couldn’t be saved.") }
        await run(id)
    }
    func finish(_ id: UUID, action: SignalAction) async throws {
        guard !isStopped, workspace.canChangeWorkspace, workspace.state.operatorSession?.paused != true, let record = workspace.state.signalItem(id: id)?.signalTask else {
            throw ActionUnavailable("The task is no longer the Operator’s.")
        }
        let next = try SignalTransitions.apply(action, to: record, at: now(), workerIsWorking: ports.workerIsWorking(id))
        workspace.mutate { $0.updateSignalTask(id) { $0 = next } }
        guard workspace.flush() else { throw ActionUnavailable("The stage couldn’t be saved.") }
        try await journal.append(.ours("Stage \(record.stage) left working."), task: id)
        if next.phase == .launching { await run(id) }
    }
    private func holds(_ claim: SignalClaim, generation expected: UUID) -> Bool {
        !isStopped && generation == expected && workspace.state.operatorSession?.paused != true
            && workspace.canChangeWorkspace && claim.holds(in: workspace.state)
            && workspace.state.signalItem(id: claim.task)?.signalTask?.phase == .launching && !Task.isCancelled
    }
}
