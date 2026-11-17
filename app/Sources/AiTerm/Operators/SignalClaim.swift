import Foundation
import AiTermCore

/// Authority belongs to one task stage and ownership generation, across every suspension.
struct SignalClaim: Equatable {
    let task: UUID, signal: UUID
    let stage: Int, ownership: Int
    init?(_ task: TaskItem) {
        guard let record = task.signalTask else { return nil }
        self.task = task.id; signal = record.signal; stage = record.stage; ownership = record.ownership
    }
    func holds(in state: AppState) -> Bool {
        state.signalItem(id: task).flatMap(Self.init) == self
    }
    func canAct(in state: AppState) -> Bool {
        guard holds(in: state), state.operatorSession?.paused != true,
              state.signal(id: signal)?.enabled != false,
              let record = state.signalItem(id: task)?.signalTask, record.phase != .stopped,
              let configuration = record.configuration ?? state.signal(id: signal),
              configuration.source.isSupported, configuration.finish.isValid(for: configuration.source) else { return false }
        if case .unknown = record.phase { return false }
        return true
    }

}
