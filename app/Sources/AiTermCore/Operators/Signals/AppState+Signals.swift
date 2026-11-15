import Foundation

public extension AppState {
    /// Unplugged must bridge quiet turns while sources or retained stages can schedule work.
    var operatorMayStartWork: Bool {
        guard operatorSession?.paused != true else { return false }
        if signals.contains(where: \.isRunnable) { return true }
        return allSignalTasks.contains { task in
            guard let record = task.signalTask, !record.takenOver,
                  signal(id: record.signal)?.enabled != false,
                  let configuration = record.configuration ?? signal(id: record.signal), configuration.isRunnable else { return false }
            switch record.phase {
            case .launching, .working, .watching, .blocked: return true
            case .done: return record.thenApplied != true || !record.pendingStages.isEmpty
            case .archived: return !record.pendingStages.isEmpty
            case .stopped, .unknown: return false
            }
        }
    }
    func signal(id: UUID) -> Signal? { signals.first { $0.id == id } }
    var allSignalTasks: [TaskItem] { tasks.filter { $0.signalTask != nil } + archive.map(\.task).filter { $0.signalTask != nil } }
    func signalItem(id: UUID) -> TaskItem? { task(id: id) ?? archived(id: id)?.task }
    mutating func updateSignalItem(_ id: UUID, _ change: (inout TaskItem) throws -> Void) rethrows {
        if let index = tasks.firstIndex(where: { $0.id == id }) { try change(&tasks[index]) }
        else if let index = archive.firstIndex(where: { $0.id == id }) { try change(&archive[index].task) }
    }
    mutating func updateSignalTask(_ id: UUID, _ change: (inout SignalTask) throws -> Void) rethrows {
        try updateSignalItem(id) { task in
            guard var record = task.signalTask else { return }
            try change(&record); task.signalTask = record
        }
    }
}
