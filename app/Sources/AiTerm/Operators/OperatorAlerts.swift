import Foundation
import AiTermCore

/// The questions the operator menus ask before acting. None deletes anything for good — a stopped
/// task keeps its window and branch, an ended broadcast's started tasks stay, so no default is red; ⎋ is
/// Cancel on each (`docs/keyboard.md`, Alerts).
enum OperatorAlerts {
    static func stopTask(_ task: TaskItem) -> AlertPrompt {
        AlertPrompt(message: "Stop “\(task.title)”?",
                    detail: "Its operator stops on it for good, and the tasks that build on it wait for you. Its window and its branch stay; an agent at work there finishes its turn.",
                    buttons: ["Stop Task", "Cancel"])
    }
    /// End Broadcast… (spec §13): what happens to the `unstarted` tasks and the `running` ones, a sentence
    /// with a count of 0 left out and a count of 1 singular. A blue default: nothing is deleted.
    static func endBroadcast(_ run: OperatorRun, unstarted: Int, running: Int) -> AlertPrompt {
        var detail: [String] = []
        if unstarted == 1 { detail.append("1 task that hasn’t started will be dropped.") }
        if unstarted > 1 { detail.append("\(unstarted) tasks that haven’t started will be dropped.") }
        if running == 1 { detail.append("1 running task finishes its turn and becomes yours.") }
        if running > 1 { detail.append("\(running) running tasks finish their turn and become yours.") }
        detail.append("Worktrees and MRs stay.")
        return AlertPrompt(message: "End “\(run.name)”?", detail: detail.joined(separator: " "), buttons: ["End Broadcast", "Cancel"])
    }
}
