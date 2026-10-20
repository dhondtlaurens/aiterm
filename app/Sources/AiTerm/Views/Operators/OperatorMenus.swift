import SwiftUI
import AiTermUI
import AiTermCore

/// One Operator item in a sidebar menu, in the picked design's words (proposal, 19 Oct 2026). The
/// items are values so each menu's contents and order are tested without opening it; a view draws
/// them with `OperatorMenuButtons`.
enum OperatorMenuItem: Hashable {
    case newBroadcast
    case rename, pause, resume, endBroadcast
    case takeOver, handBack, stopTask
    case separator

    var title: String {
        switch self {
        case .newBroadcast: "New Broadcast…"
        case .rename: "Rename…"
        case .pause: "Pause Broadcast"
        case .resume: "Resume Broadcast"
        case .endBroadcast: "End Broadcast…"
        case .takeOver: "Take Over"
        case .handBack: "Hand Back"
        case .stopTask: "Stop Task…"
        case .separator: ""
        }
    }

    /// Drawn in the menu's destructive red: Stop Task…, which ends the task for its Operator. End
    /// Broadcast… is not: nothing is deleted, and its alert's default is blue (spec §13).
    var isDestructive: Bool { self == .stopTask }
}

/// Which items each Operator menu holds, in order.
enum OperatorMenus {
    /// The OPERATOR heading's "+", shown only while no broadcast exists: the one way to start one.
    static let headingPlus: [OperatorMenuItem] = [.newBroadcast]

    /// The broadcast row's menu: Rename…; Pause Broadcast while it can run, Resume Broadcast while it is
    /// paused or its Operator's window is closed, neither once the debrief is ready; End Broadcast…. No
    /// Overview… (a click opens it) and no Interrupt Agents: an agent always finishes its turn (spec §9).
    static func broadcast(_ run: OperatorRun) -> [OperatorMenuItem] {
        if run.state == .complete { return [.rename, .separator, .endBroadcast] }
        let paused = run.state == .paused || run.state == .operatorOffline || run.intent == .paused
        return [.rename, .separator, paused ? .resume : .pause, .separator, .endBroadcast]
    }

    /// What a task row's menu leads with while the Operator drives the task: Take Over, or Hand Back
    /// while you have taken it over — whatever its state, so ownership is never stranded with you once
    /// a task has ended (an accepted one still awaits its `finish_task`) — then, only while the task is
    /// open, Stop Task… (it asks first). Nothing once its broadcast has ended (`TaskRow.broadcastLive`):
    /// its tasks were handed to you, and there is no Operator to hand one back to.
    static func task(_ operated: OperatedTask?, broadcastLive: Bool) -> [OperatorMenuItem] {
        guard let operated, broadcastLive else { return [] }
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
