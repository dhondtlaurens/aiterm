import Foundation
import AiTermCore

/// Authority belongs to one task stage and ownership generation, across every suspension.
struct SignalClaim: Equatable {
    let task: UUID, signal: UUID
    let stage: Int, ownership: Int
    init?(_ task: TaskItem) {
        guard let record = task.signalTask else { return nil }
        self.task = task.id; signal = record.current.signal; stage = record.stage; ownership = record.ownership
    }
    func holds(in state: AppState) -> Bool {
        state.signalItem(id: task).flatMap(Self.init) == self
    }
    /// Whether an effect owner may still act on this claim: the workspace can change, the claim
    /// holds, the Operator is not paused, its signal is not switched off, the stage's configuration
    /// is valid, its phase is known, and the current task is not cancelled.
    @MainActor func allows(in workspace: WorkspaceStore) -> Bool {
        let state = workspace.state
        guard workspace.canChangeWorkspace, !Task.isCancelled, holds(in: state), state.operatorSession?.paused != true,
              state.signal(id: signal)?.enabled != false,
              let record = state.signalItem(id: task)?.signalTask else { return false }
        return record.current.configuration.isValid
    }
}
