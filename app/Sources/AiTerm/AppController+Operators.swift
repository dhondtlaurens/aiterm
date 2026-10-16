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

extension AppController {
    /// OPERATORS' "+": a new operator, its file named from its name.
    func presentNewOperator() {
        presentOperatorSheet(editing: nil)
    }

    /// An operator header's Edit Operator…: the same sheet, titled with its name.
    func presentEditOperator(_ persona: OperatorPersona) {
        presentOperatorSheet(editing: persona)
    }

    /// The names taken are the library's own count — the files in its folder, an unreadable one too —
    /// asked again when Create is pressed, so a new operator's file, named as `uniqueHandle` would name
    /// it, never lands on one, and `createOperator` refuses it if one lands there in between. An edit
    /// writes its own file.
    private func presentOperatorSheet(editing persona: OperatorPersona?) {
        let controller = operatorController
        sheets.presentOperatorSheet(editing: persona, takenHandles: { controller.ports.library.takenHandles() }) {
            if persona == nil { try controller.createOperator($0) } else { try controller.saveOperator($0) }
        }
    }
}
