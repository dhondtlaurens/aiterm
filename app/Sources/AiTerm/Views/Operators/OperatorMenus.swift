import SwiftUI
import AiTermUI
import AiTermCore

/// One Operator item in a sidebar menu, in the picked design's words (proposal, 19 Oct 2026). The
/// items are values so each menu's contents and order are tested without opening it; a view draws
/// them with `OperatorMenuButtons`.
enum OperatorMenuItem: Hashable {
    case newBroadcast
    case openBoard, rename, pause, resume, endBroadcast
    case takeOver, handBack, stopTask
    case separator

    var title: String {
        switch self {
        case .newBroadcast: "New Broadcast…"
        case .openBoard: "Open Board"
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

    /// The item as a VoiceOver action names it: its title without the menu's ellipsis.
    var actionTitle: String { title.hasSuffix("…") ? String(title.dropLast()) : title }

    /// Drawn in the menu's destructive red: Stop Task…, which ends the task for its Operator. End
    /// Broadcast… is not: nothing is deleted, and its alert's default is blue (spec §13).
    var isDestructive: Bool { self == .stopTask }
}

/// Which items each Operator menu holds, in order.
enum OperatorMenus {
    /// The OPERATOR heading's "+", shown only while no broadcast exists: the one way to start one.
    static let headingPlus: [OperatorMenuItem] = [.newBroadcast]

    /// The broadcast's menu, OPERATOR's and its lead row's: Open Board, as its board button does; Rename…; Pause Broadcast while it
    /// can run, Resume Broadcast while it is paused or its Operator's window is closed, neither once every
    /// task is done, its summary written or not; End Broadcast…. No Interrupt Agents: an agent always finishes its
    /// turn (spec §9). Read from the header (`BroadcastRow.isPaused`, `isDone`), so the menu changes only with it.
    static func broadcast(_ row: BroadcastRow) -> [OperatorMenuItem] {
        if row.isDone { return [.openBoard, .separator, .rename, .separator, .endBroadcast] }
        return [.openBoard, .separator, .rename, .separator, row.isPaused ? .resume : .pause, .separator, .endBroadcast]
    }

    /// What a task row's menu leads with while the Operator drives the task: Take Over, or Hand Back
    /// while you have taken it over — whatever its state, so ownership is never stranded with you once
    /// a task has ended (an accepted one still awaits its `finish_task`) — then, only while the task is
    /// open, Stop Task… (it asks first). Nothing once its broadcast has ended (`TaskRow.broadcastLive`):
    /// its tasks were handed to you, and there is no Operator to hand one back to.
    static func task(_ operated: OperatedTask?, broadcastLive: Bool) -> [OperatorMenuItem] {
        guard let operated, broadcastLive else { return [] }
        let owner: OperatorMenuItem = operated.takenOver ? .handBack : .takeOver
        return (operated.state.isOpen || (operated.state == .accepted && operated.publication?.leftForYou != true)) ? [owner, .separator, .stopTask] : [owner]
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
