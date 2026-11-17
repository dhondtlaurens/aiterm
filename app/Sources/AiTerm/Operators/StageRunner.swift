import Foundation
import AiTermCore

/// Persist stage and launch intents before effects. A stage never reaches a worker mid-turn and
/// every await is followed by an ownership check, so Take Over, which removes the record, invalidates late completions.
@MainActor final class StageRunner {
    struct Ports {
        var workerIsWorking: @MainActor (UUID) -> Bool
        /// The task's worker checkout, saved on the task.
        var prepare: @MainActor (TaskItem, Signal) async throws -> TaskItem
        var launch: @MainActor (TaskItem, String) async throws -> String
        /// The archived task's worktree recreated and its row back in the sidebar.
        var restore: @MainActor (TaskItem) async throws -> TaskItem
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
        guard !isStopped, !running.contains(id), !ports.workerIsWorking(id),
              let initial = workspace.state.signalItem(id: id), let claim = SignalClaim(initial), claim.allows(in: workspace),
              let record = initial.signalTask, record.phase == .launching, record.current.configuration.isRunnable else { return }
        let signal = record.current.configuration
        let launchGeneration = generation
        running.insert(id); defer {
            running.remove(id)
            workspace.mutate { state in if claim.holds(in: state) { state.updateSignalTask(id) { $0.currentAct = nil } } }
        }
        do {
            // The row comes back to the sidebar with its worktree, even when the claim was lost meanwhile.
            if workspace.state.archived(id: id) != nil {
                _ = try await ports.restore(initial)
                guard holds(claim, generation: launchGeneration) else { return }
            }
            guard holds(claim, generation: launchGeneration), !ports.workerIsWorking(id) else { return }
            let attempt = LaunchAttempt(number: (record.launch?.number ?? 0) + 1, requestedAt: now(), workerPending: true)
            workspace.mutate { state in
                state.updateSignalItem(id) { task in
                    task.firstPrompt = task.signalTask?.current.prompt ?? signal.work.prompt
                    task.signalTask?.launch = attempt
                    task.signalTask?.currentAct = "starting its worker"
                }
            }
            guard workspace.flush() else { return }
            try await journal.append(.ours("Starting stage \(record.stage) from \(signal.name)."), task: id)
            guard holds(claim, generation: launchGeneration), let before = workspace.state.task(id: id) else { return }
            // The checkout saves itself on the task, even once the claim is lost.
            if !before.hasCheckout { _ = try await ports.prepare(before, signal) }
            guard holds(claim, generation: launchGeneration), !ports.workerIsWorking(id), let task = workspace.state.task(id: id) else { return }
            let prompt = WorkerPrompt.worktreeLine(branch: task.branch) + "\n\n" + (task.firstPrompt ?? signal.work.prompt)
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
            guard !isStopped, generation == launchGeneration, claim.allows(in: workspace),
                  let record = workspace.state.signalItem(id: id)?.signalTask,
                  let next = try? SignalTransitions.apply(.launchFailed(OperationIssue.reason(of: error)), to: record, at: now()) else { return }
            workspace.mutate { $0.updateSignalTask(id) { $0 = next } }
            workspace.flush()
            changed(id, "Its worker could not start.")
        }
    }
    /// Resumes a blocked stage on its decided row and project. Changing either is a choice, made
    /// through `choose` after the Operator and the Oracle agree.
    func resume(_ id: UUID, project: UUID? = nil, agent: AgentChoice? = nil) async throws {
        if workspace.state.signalItem(id: id)?.signalTask?.phase == .choosing {
            throw ActionUnavailable("This stage waits for its agent choice. Use choose_agent.")
        }
        guard !ports.workerIsWorking(id), !isStopped,
              let task = workspace.state.signalItem(id: id), let claim = SignalClaim(task), claim.allows(in: workspace), let record = task.signalTask,
              record.phase == .blocked, record.current.configuration.isRunnable else {
            throw ActionUnavailable("Only a blocked task of the Operator can be resumed.")
        }
        let signal = record.current.configuration
        let current = AgentChoice(agent: task.agent, model: task.model, reasoning: task.reasoning)
        if let project, project != task.projectId { throw ActionUnavailable("resume_task keeps the task's project. Use choose_agent to change it.") }
        if let agent, agent != current { throw ActionUnavailable("resume_task keeps the decided agent row. Use choose_agent to change it.") }
        guard signal.agents.contains(current), AgentCommand.workerAgents.contains(current.agent), !current.model.isEmpty else {
            throw ActionUnavailable("Its agent row is no longer permitted. Use choose_agent to choose one.")
        }
        let next = try SignalTransitions.apply(.resume, to: record, at: now())
        workspace.mutate { $0.updateSignalItem(id) { task in task.signalTask = next; task.signalTask?.candidateProjects = nil } }
        guard workspace.flush() else { throw ActionUnavailable("The resume intent couldn’t be saved.") }
        await run(id)
    }
    /// Applies a decided row and project to a choosing stage, or to a blocked stage that resumes on
    /// a new row, journals the choice and starts the stage. The caller validated the choice.
    func choose(_ id: UUID, choice: AgentChoiceRecord) async throws {
        guard !ports.workerIsWorking(id), !isStopped,
              let task = workspace.state.signalItem(id: id), let claim = SignalClaim(task), claim.allows(in: workspace), let record = task.signalTask,
              record.phase == .choosing || record.phase == .blocked, record.current.configuration.isRunnable else {
            throw ActionUnavailable("Only a choosing or blocked task of the Operator takes an agent choice.")
        }
        if let project = choice.project, project != task.projectId {
            guard workspace.state.project(id: project) != nil else { throw ActionUnavailable("That project is no longer in the sidebar.") }
            guard !task.hasCheckout else { throw ActionUnavailable("A task with a checkout cannot move repositories.") }
        }
        let next = try SignalTransitions.apply(record.phase == .choosing ? .chosen : .resume, to: record, at: now())
        workspace.mutate { $0.updateSignalItem(id) { task in
            task.signalTask = next; task.signalTask?.candidateProjects = nil; task.signalTask?.choice = choice
            if let project = choice.project { task.projectId = project }
            task.agent = choice.row.agent; task.model = choice.row.model; task.reasoning = choice.row.reasoning
        } }
        guard workspace.flush() else { throw ActionUnavailable("The agent choice couldn’t be saved.") }
        try await journal.append(.ours(choice.journalLine), task: id)
        changed(id, "The Operator chose its agent.")
        await run(id)
    }
    func finish(_ id: UUID, action: SignalAction, judged: Bool = false) async throws {
        guard !isStopped, let task = workspace.state.signalItem(id: id), let claim = SignalClaim(task), claim.allows(in: workspace), let record = task.signalTask else {
            throw ActionUnavailable("The task is no longer the Operator’s.")
        }
        var next = try SignalTransitions.apply(action, to: record, at: now(), workerIsWorking: ports.workerIsWorking(id))
        if judged, next.stage == record.stage { next.operatorJudged = true }
        workspace.mutate { state in
            state.updateSignalItem(id) { task in
                task.signalTask = next
                if next.phase == .launching { task.prepareLaunch(candidates: nil, at: now()) }
            }
        }
        guard workspace.flush() else { throw ActionUnavailable("The stage couldn’t be saved.") }
        try await journal.append(.ours("Stage \(record.stage) left working."), task: id)
        if workspace.state.signalItem(id: id)?.signalTask?.phase == .launching { await run(id) }
        else if workspace.state.signalItem(id: id)?.signalTask?.phase == .choosing { changed(id, "The Operator chooses this stage's agent.") }
        else if workspace.state.signalItem(id: id)?.signalTask?.phase == .blocked { changed(id, "This stage cannot start.") }
    }
    private func holds(_ claim: SignalClaim, generation expected: UUID) -> Bool {
        !isStopped && generation == expected && claim.allows(in: workspace)
            && workspace.state.signalItem(id: claim.task)?.signalTask?.phase == .launching
    }
}
