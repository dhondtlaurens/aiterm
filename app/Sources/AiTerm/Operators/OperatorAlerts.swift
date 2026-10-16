import Foundation
import AiTermCore

/// The questions the operator menus ask before acting. None deletes anything for good — a stopped
/// task keeps its window and branch, the operator's file goes to the Trash, an ended operation's tasks
/// stay — so no default is red; ⎋ is Cancel on each (`docs/keyboard.md`, Alerts).
enum OperatorAlerts {
    static func stopTask(_ task: TaskItem) -> AlertPrompt {
        AlertPrompt(message: "Stop “\(task.title)”?",
                    detail: "Its operator stops on it for good, and the tasks that build on it wait for you. Its window and its branch stay; an agent at work there finishes its turn.",
                    buttons: ["Stop Task", "Cancel"])
    }
}
