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
    private var running: Set<UUID> = []
    func isRunning(_ id: UUID) -> Bool { running.contains(id) }
    init(workspace: WorkspaceStore, journal: SignalJournal, stages: StageRunner, now: @escaping () -> Date, ports: Ports) {
        self.workspace = workspace; self.journal = journal; self.stages = stages; self.now = now; self.ports = ports
    }
    func apply(_ id: UUID) async {
        guard workspace.canChangeWorkspace, workspace.state.operatorSession?.paused != true,
              !running.contains(id), !ports.workerIsWorking(id), let task = workspace.state.task(id: id),
              let claim = SignalClaim(task), claim.canAct(in: workspace.state), let record = task.signalTask, record.canRunThen, record.thenApplied != true,
              let signal = record.configuration ?? workspace.state.signal(id: record.signal) else { return }
        let allowed: @MainActor () -> Bool = { [self] in
            workspace.canChangeWorkspace && workspace.state.operatorSession?.paused != true && !Task.isCancelled
                && claim.canAct(in: workspace.state) && workspace.state.signalItem(id: id)?.signalTask?.canRunThen == true
                && !ports.workerIsWorking(id)
        }
        running.insert(id)
        defer {
            running.remove(id)
            if claim.holds(in: workspace.state) { workspace.mutate { $0.updateSignalTask(id) { $0.currentAct = nil } } }
        }
        do {
            try await journal.append(.ours("Applying Then: " + signal.finish.then.rawValue + "."), task: id)
            guard allowed() else { return }
            switch signal.finish.then {
            case .unknown: return
            case .keep: break
            case .archive:
                workspace.mutate { $0.updateSignalTask(id) { $0.currentAct = "archiving it" } }
                guard workspace.flush() else { return }
                guard let current = workspace.state.task(id: id) else { return }
                try await ports.archive(current, allowed)
                if allowed() {
                    try workspace.mutate { state in
                        try state.updateSignalTask(id) { $0 = try SignalTransitions.apply(.archive, to: $0, at: now()) }
                    }
                }
            case .remove:
                workspace.mutate { $0.updateSignalTask(id) { $0.currentAct = "removing it" } }
                guard workspace.flush() else { return }
                guard let current = workspace.state.task(id: id) else { return }
                try await ports.remove(current, allowed)
            }
            if allowed() || workspace.state.archived(id: id)?.task.signalTask?.phase == .archived {
                workspace.mutate { $0.updateSignalTask(id) { $0.thenApplied = true } }
                workspace.flush()
            }
        } catch {
            guard claim.canAct(in: workspace.state), !Task.isCancelled else { return }
            // A person's or worker's turn, and a disconnected helper, are retried. Unsaved work
            // stays for the person, as the existing prompt-free removal does.
            if !(error is ClosingWait), workspace.state.signalItem(id: id)?.signalTask?.pendingStages.isEmpty == true {
                workspace.mutate { $0.updateSignalTask(id) { $0.thenApplied = true; $0.blockedReason = OperationIssue.reason(of: error) } }
                workspace.flush()
            }
        }
        if let current = workspace.state.signalItem(id: id)?.signalTask, current.phase.canContinue, !current.pendingStages.isEmpty {
            try? await stages.finish(id, action: .advancePending)
        }
    }
}
