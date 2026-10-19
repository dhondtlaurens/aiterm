import SwiftUI
import AiTermUI
import AiTermCore

/// One operator item in a sidebar menu, in the picked design's words (proposal, 16 Oct 2026). The
/// items are values so each menu's contents and order are tested without opening it; a view draws
/// them with `OperatorMenuButtons`.
enum OperatorMenuItem: Hashable {
    case newOperation
    case overview, rename, pause, resume, endOperation
    case takeOver, handBack, stopTask
    case separator

    var title: String {
        switch self {
        case .newOperation: "New Operation…"
        case .overview: "Overview…"
        case .rename: "Rename…"
        case .pause: "Pause"
        case .resume: "Resume"
        case .endOperation: "End Operation…"
        case .takeOver: "Take Over"
        case .handBack: "Hand Back"
        case .stopTask: "Stop Task…"
        case .separator: ""
        }
    }

    /// Drawn in the menu's destructive red: the two that end something. Each asks first.
    var isDestructive: Bool { self == .endOperation || self == .stopTask }
}

/// Which items each operator menu holds, in order.
enum OperatorMenus {
    /// OPERATORS' "+".
    static let operatorsGroup: [OperatorMenuItem] = [.newOperation]
    /// The Operator header's "+".
    static let headerPlus: [OperatorMenuItem] = [.newOperation]
    /// The Operator header's context menu.
    static let header: [OperatorMenuItem] = [.newOperation]

    /// An operation row's context menu: Overview… and Rename…; Pause while it can run, Resume while it
    /// is paused or its operator is offline, neither once it is complete. Ending never interrupts an agent:
    /// it finishes its turn (spec §9).
    static func operation(_ state: OperatorRunState) -> [OperatorMenuItem] {
        switch state {
        case .paused, .operatorOffline: [.overview, .rename, .separator, .resume, .separator, .endOperation]
        case .complete, .stopped: [.overview, .rename, .separator, .endOperation]
        case .planning, .active: [.overview, .rename, .separator, .pause, .separator, .endOperation]
        }
    }

    /// What a task row's menu leads with while an operator drives the task: Take Over, or Hand Back
    /// while you have taken it over — whatever its state, so ownership is never stranded with you once
    /// a task has ended (an accepted one still awaits its `finish_task`) — then, only while the task is
    /// open, Stop Task… (spec §8: "Stop task in the row's menu").
    static func task(_ operated: OperatedTask?) -> [OperatorMenuItem] {
        guard let operated else { return [] }
        let owner: OperatorMenuItem = operated.takenOver ? .handBack : .takeOver
        return operated.state.isOpen ? [owner, .separator, .stopTask] : [owner]
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
