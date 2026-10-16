import SwiftUI
import AiTermUI
import AiTermCore

/// One operator item in a sidebar menu, in the picked design's words (proposal, 16 Oct 2026). The
/// items are values so each menu's contents and order are tested without opening it; a view draws
/// them with `OperatorMenuButtons`.
enum OperatorMenuItem: Hashable {
    case newOperator, newOperation, editOperator, duplicate, moveToTrash
    case overview, rename, pause, resume, interruptAgents, endOperation
    case takeOver, handBack, stopTask
    case separator

    var title: String {
        switch self {
        case .newOperator: "New Operator…"
        case .newOperation: "New Operation…"
        case .editOperator: "Edit Operator…"
        case .duplicate: "Duplicate"
        case .moveToTrash: "Move to Trash…"
        case .overview: "Overview…"
        case .rename: "Rename…"
        case .pause: "Pause"
        case .resume: "Resume"
        case .interruptAgents: "Interrupt Agents"
        case .endOperation: "End Operation…"
        case .takeOver: "Take Over"
        case .handBack: "Hand Back"
        case .stopTask: "Stop Task…"
        case .separator: ""
        }
    }

    /// Drawn in the menu's destructive red: the three that end something. Each asks first.
    var isDestructive: Bool { self == .moveToTrash || self == .endOperation || self == .stopTask }
}

/// Which items each operator menu holds, in order.
enum OperatorMenus {
    /// OPERATORS' "+".
    static let operatorsGroup: [OperatorMenuItem] = [.newOperator]
    /// An operator header's "+".
    static let headerPlus: [OperatorMenuItem] = [.newOperation]
    /// An operator header's context menu.
    static let header: [OperatorMenuItem] = [.newOperation, .separator, .editOperator, .duplicate, .separator, .moveToTrash]

    /// An operation row's context menu: Overview… and Rename…; Pause while it can run, Resume while it
    /// is paused or its operator is offline, and Interrupt Agents — each agent's own interrupt key, on
    /// your click only (spec §9) — while any can be at work; neither once it is complete.
    static func operation(_ state: OperatorRunState) -> [OperatorMenuItem] {
        switch state {
        case .paused, .operatorOffline: [.overview, .rename, .separator, .resume, .interruptAgents, .separator, .endOperation]
        case .complete, .stopped: [.overview, .rename, .separator, .endOperation]
        case .planning, .active: [.overview, .rename, .separator, .pause, .interruptAgents, .separator, .endOperation]
        }
    }

    /// What a task row's menu leads with while an operator drives the task: Take Over, or Hand Back once
    /// you have; then Stop Task…. All of it only while the task is open — what Stop can still stop, and
    /// what the row still calls "taken over" (spec §8: "Stop task in the row's menu"). A finished or
    /// stopped task has nothing to take over, hand back or stop.
    static func task(_ operated: OperatedTask?) -> [OperatorMenuItem] {
        guard let operated, operated.state.isOpen else { return [] }
        return [operated.takenOver ? .handBack : .takeOver, .separator, .stopTask]
    }
}

/// `items` as menu buttons and dividers. `enabled` greys an item, as a locked workspace greys the
/// rest of a row's menu; `perform` runs the chosen one.
struct OperatorMenuButtons: View {
    let items: [OperatorMenuItem]
    var enabled: (OperatorMenuItem) -> Bool = { _ in true }
    let perform: (OperatorMenuItem) -> Void

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if item == .separator {
                Divider()
            } else {
                Button(item.title, role: item.isDestructive ? .destructive : nil) { perform(item) }
                    .disabled(!enabled(item))
            }
        }
    }
}
