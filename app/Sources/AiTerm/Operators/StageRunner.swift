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
        /// Whether the stage's Done query matches its item now: the baseline its done edge is read against.
        var doneMatches: @MainActor (TaskItem) async throws -> Bool = { _ in false }
    }
    private let workspace: WorkspaceStore
    private let journal: SignalJournal
    private let now: () -> Date
    private let ports: Ports
    private let effects: OperatorInFlight
    /// Where a launch shows as its task's act.
    private let activity: OperatorActivityTracker
    private var isStopped = false
    private var generation = UUID()
    /// A stage whose Done trigger could not be read waits until then before it is read again.
    private var heldUntil: [UUID: (stage: Int, until: Date)] = [:]
    /// How long a held launch waits before its Done trigger is read again: as long as a source's failed read.
    static let heldBackOff = SignalPoller.failureBackOff
    func start() { isStopped = false }
    func stop() { isStopped = true; generation = UUID() }
    var changed: (UUID, String) -> Void = { _, _ in }
    init(workspace: WorkspaceStore, journal: SignalJournal, now: @escaping () -> Date, ports: Ports,
         effects: OperatorInFlight = OperatorInFlight(), activity: OperatorActivityTracker = OperatorActivityTracker()) {
        self.workspace = workspace; self.journal = journal; self.now = now; self.ports = ports; self.effects = effects; self.activity = activity
    }
    /// Whether `id`'s worker is at work or another Operator effect holds the task.
    private func atWork(_ id: UUID) -> Bool { ports.workerIsWorking(id) || effects.holds(id) }
    /// Launches a launching stage, holding the task from its restore through its launch.
    func run(_ id: UUID) async {
        guard !isStopped, !ports.workerIsWorking(id),
              let initial = workspace.state.signalItem(id: id), let claim = SignalClaim(initial), claim.allows(in: workspace),
              let record = initial.signalTask, record.phase == .launching, record.current.configuration.isRunnable,
              effects.claim(id) else { return }
        let signal = record.current.configuration
        let launchGeneration = generation
        defer { effects.release(id) }
        do {
            // The row comes back to the sidebar with its worktree, even when the claim was lost meanwhile.
            if workspace.state.archived(id: id) != nil {
                _ = try await ports.restore(initial)
                guard holds(claim, generation: launchGeneration) else { return }
            }
            guard holds(claim, generation: launchGeneration), !ports.workerIsWorking(id) else { return }
            guard try await baseline(id, claim: claim, generation: launchGeneration) else { return }
            let launched: String? = try await activity.acting(task: id, act: "starting its worker") {
                let attempt = LaunchAttempt(number: (record.launch?.number ?? 0) + 1, requestedAt: now(), workerPending: true)
                workspace.mutate { state in
                    state.updateSignalItem(id) { task in
                        task.firstPrompt = task.signalTask?.current.prompt ?? signal.work.prompt
                        task.signalTask?.launch = attempt
                    }
                }
                guard workspace.flush() else { return nil }
                try await journal.append(.ours("Starting stage \(record.stage) from \(signal.name)."), task: id)
                guard holds(claim, generation: launchGeneration), let before = workspace.state.task(id: id) else { return nil }
                // The checkout saves itself on the task, even once the claim is lost.
                if !before.hasCheckout { _ = try await ports.prepare(before, signal) }
                guard holds(claim, generation: launchGeneration), !ports.workerIsWorking(id), let task = workspace.state.task(id: id) else { return nil }
                let prompt = WorkerPrompt.worktreeLine(branch: task.branch) + "\n\n" + (task.firstPrompt ?? signal.work.prompt)
                return try await ports.launch(task, prompt)
            }
            guard let window = launched, holds(claim, generation: launchGeneration) else { return }
            let at = now()
            try workspace.mutate { state in
                try state.updateSignalItem(id) { task in
                    guard let record = task.signalTask else { return }
                    task.signalTask = try SignalTransitions.apply(.workerStarted, to: record, at: at)
                    task.signalTask?.launch?.openedAt = at
                    task.windowId = window
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
    /// Reads and saves the stage's Done baseline once per stage, before its launch intent. An unreadable trigger holds
    /// the launch, the stage still launching with the reason, until the back-off ends. Whether the launch goes on.
    private func baseline(_ id: UUID, claim: SignalClaim, generation expected: UUID) async throws -> Bool {
        guard let task = workspace.state.task(id: id), let record = task.signalTask else { return false }
        if record.doneMatched != nil { return true }
        if let held = heldUntil[id], held.stage == record.stage, now() < held.until { return false }
        let matches: Bool
        do { matches = try await ports.doneMatches(task) }
        catch {
            guard holds(claim, generation: expected) else { return false }
            heldUntil[id] = (record.stage, now().addingTimeInterval(Self.heldBackOff))
            let reason = "Its Done trigger could not be read: " + OperationIssue.reason(of: error)
            workspace.mutate { $0.updateSignalTask(id) { $0.blockedReason = reason } }
            workspace.flush()
            changed(id, "Its Done trigger could not be read.")
            return false
        }
        guard holds(claim, generation: expected) else { return false }
        heldUntil[id] = nil
        workspace.mutate { $0.updateSignalTask(id) { $0.doneMatched = matches; $0.blockedReason = nil } }
        guard workspace.flush() else { throw ActionUnavailable("The stage couldn’t be saved.") }
        return true
    }
    /// Resumes a blocked stage on its decided row and project. Changing either is a choice, made
    /// through `choose` after the Operator and the Oracle agree.
    func resume(_ id: UUID, project: UUID? = nil, agent: AgentChoice? = nil) async throws {
        if workspace.state.signalItem(id: id)?.signalTask?.phase == .choosing {
            throw ActionUnavailable("This stage waits for its agent choice. Use choose_agent.")
        }
        guard !atWork(id), !isStopped,
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
    /// Applies a decided row (or its weekly-usage switch) and project to a choosing stage, or to a
    /// blocked stage that resumes on a new row, journals the choice and starts the stage. The caller
    /// validated the choice.
    func choose(_ id: UUID, choice: AgentChoiceRecord) async throws {
        guard !atWork(id), !isStopped,
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
            let row = choice.launchSwitch ?? choice.row
            task.agent = row.agent; task.model = row.model; task.reasoning = row.reasoning
        } }
        guard workspace.flush() else { throw ActionUnavailable("The agent choice couldn’t be saved.") }
        try await journal.append(.ours(choice.journalLine), task: id)
        if let row = choice.launchSwitch { try await journal.append(.ours(AgentChoiceRecord.switchLine(row)), task: id) }
        changed(id, "The Operator chose its agent.")
        await run(id)
    }
    /// Records a stage result. Any result, a block included, is refused while another Operator effect holds the task.
    func finish(_ id: UUID, action: SignalAction) async throws {
        guard !isStopped, let task = workspace.state.signalItem(id: id), let claim = SignalClaim(task), claim.allows(in: workspace), let record = task.signalTask else {
            throw ActionUnavailable("The task is no longer the Operator’s.")
        }
        guard !effects.holds(id) else { throw SignalTransitionError.workerIsWorking }
        let next = try SignalTransitions.apply(action, to: record, at: now(), workerIsWorking: atWork(id))
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
