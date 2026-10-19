import Foundation

/// Finding an operation and its tasks in the workspace, for the engines and the app alike.
public extension AppState {
    func run(id: UUID) -> OperatorRun? { runs.first { $0.id == id } }

    /// The run's tasks in sidebar order, which is the plan's order: the order they were created.
    func tasks(inRun id: UUID) -> [TaskItem] { tasks.filter { $0.operated?.runId == id } }

    mutating func updateRun(id: UUID, _ change: (inout OperatorRun) -> Void) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        change(&runs[i])
    }
}
