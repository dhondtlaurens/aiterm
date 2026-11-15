import Foundation
import AiTermCore

/// Authority belongs to one task stage and ownership generation, across every suspension.
struct SignalClaim: Equatable {
    let task: UUID, signal: UUID
    let stage: Int, ownership: Int
    init?(_ task: TaskItem) {
        guard let record = task.signalTask, !record.takenOver else { return nil }
        self.task = task.id; signal = record.signal; stage = record.stage; ownership = record.ownership
    }
    func holds(in state: AppState) -> Bool {
        state.signalItem(id: task).flatMap(Self.init) == self
    }
}
