import Foundation
import AiTermCore

/// Then runs only at the last stage. The effects recheck `allowed` before changing a checkout;
/// queued work that arrived during preflight takes precedence and continues in the same task.
@MainActor final class ThenRunner {
    struct Ports {
        var workerIsWorking: @MainActor (UUID) -> Bool
        var archive: @MainActor (TaskItem, @escaping @MainActor () -> Bool) async throws -> Void
        var remove: @MainActor (TaskItem, @escaping @MainActor () -> Bool) async throws -> Void
    }
    private let workspace: WorkspaceStore
    private let journal: SignalJournal
    private let stages: StageRunner
    private let now: () -> Date
    private let ports: Ports
    private let effects: OperatorInFlight
    /// Where an archive or removal shows as its task's act.
    private let activity: OperatorActivityTracker
    init(workspace: WorkspaceStore, journal: SignalJournal, stages: StageRunner, now: @escaping () -> Date, ports: Ports,
         effects: OperatorInFlight = OperatorInFlight(), activity: OperatorActivityTracker = OperatorActivityTracker()) {
        self.workspace = workspace; self.journal = journal; self.stages = stages; self.now = now; self.ports = ports; self.effects = effects
        self.activity = activity
    }
    /// Applies Then holding the task, then, with the task released, starts a stage that arrived meanwhile: that
    /// stage's launch claims the task itself.
    func apply(_ id: UUID) async {
        guard !ports.workerIsWorking(id), let task = workspace.state.task(id: id),
              let claim = SignalClaim(task), claim.allows(in: workspace), let record = task.signalTask, record.canRunThen, record.thenApplied != true,
              effects.claim(id) else { return }
        let signal = record.current.configuration
        let allowed: @MainActor () -> Bool = { [self] in
            claim.allows(in: workspace) && workspace.state.signalItem(id: id)?.signalTask?.canRunThen == true
                && !ports.workerIsWorking(id)
        }
        do {
            defer { effects.release(id) }
            do {
                try await journal.append(.ours("Applying Then: " + signal.finish.then.rawValue + "."), task: id)
                guard allowed() else { return }
                switch signal.finish.then {
                case .unknown: return
                case .keep: break
                case .archive:
                    guard let current = workspace.state.task(id: id) else { return }
                    try await activity.acting(task: id, act: "archiving it") {
                        try await ports.archive(current, allowed)
                        if allowed() {
                            try workspace.mutate { state in
                                try state.updateSignalTask(id) { $0 = try SignalTransitions.apply(.archive, to: $0, at: now()) }
                            }
                        }
                    }
                case .remove:
                    guard let current = workspace.state.task(id: id) else { return }
                    try await activity.acting(task: id, act: "removing it") { try await ports.remove(current, allowed) }
                }
                if allowed() || workspace.state.archived(id: id)?.task.signalTask?.phase == .archived {
                    workspace.mutate { $0.updateSignalTask(id) { $0.thenApplied = true } }
                    workspace.flush()
                }
            } catch {
                guard claim.allows(in: workspace) else { return }
                // A person's or worker's turn, and a disconnected helper, are retried. Unsaved work
                // stays for the person, as the existing prompt-free removal does.
                if !(error is ClosingWait), workspace.state.signalItem(id: id)?.signalTask?.pendingStages.isEmpty == true {
                    workspace.mutate { $0.updateSignalTask(id) { $0.thenApplied = true; $0.blockedReason = OperationIssue.reason(of: error) } }
                    workspace.flush()
                }
            }
        }
        if let current = workspace.state.signalItem(id: id)?.signalTask, current.phase.canContinue, !current.pendingStages.isEmpty {
            try? await stages.finish(id, action: .advancePending)
        }
    }
}
