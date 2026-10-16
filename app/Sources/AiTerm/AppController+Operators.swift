import Foundation
import AiTermCore

/// What the operator views ask of the app, forwarded to the operator controller (Part D). A refusal
/// lands in the banner, as every other action's does, named after what it was for.
extension AppController {
    /// A driven task row's Take Over, Hand Back or Stop Task….
    func perform(_ item: OperatorMenuItem, on task: TaskItem) {
        let controller = operatorController
        switch item {
        case .takeOver:
            attempt("Couldn’t take over “\(task.title)”") { try await controller.takeOver(task: task.id) }
        case .handBack:
            attempt("Couldn’t hand “\(task.title)” back") { try await controller.handBack(task: task.id) }
        case .stopTask:
            Task { await confirmStop(task) }
        default:
            break
        }
    }

    /// Stop Task…: asks first, then the task ends `stopped` for its operator — its dependents wait for
    /// you; its window, branch and any agent at work stay. Says whether it was stopped.
    @discardableResult
    func confirmStop(_ task: TaskItem) async -> Bool {
        guard await prompter.ask(OperatorAlerts.stopTask(task)).confirmed else { return false }
        let controller = operatorController
        attempt("Couldn’t stop “\(task.title)”") { try await controller.stop(task: task.id) }
        return true
    }

    /// Runs `work` and reports what it threw as `title`.
    func attempt(_ title: String, _ work: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await work() } catch { report(OperationIssue(title: title + ".", error: error)) }
        }
    }
}
