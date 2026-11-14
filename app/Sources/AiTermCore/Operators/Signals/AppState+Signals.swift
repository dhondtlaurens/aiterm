import Foundation

public extension AppState {
    func signal(id: UUID) -> Signal? { signals.first { $0.id == id } }
    var allSignalTasks: [TaskItem] { tasks.filter { $0.signalTask != nil } + archive.map(\.task).filter { $0.signalTask != nil } }
    mutating func updateSignalTask(_ id: UUID, _ change: (inout SignalTask) throws -> Void) rethrows {
        guard let index = tasks.firstIndex(where: { $0.id == id }), var record = tasks[index].signalTask else { return }
        try change(&record); tasks[index].signalTask = record
    }
}
