import Foundation

enum WorkerPrompt {
    nonisolated static func worktreeLine(branch: String, asks: Bool = true) -> String {
        "[AiTerm] You are already in this task's worktree, on branch \(branch). Commit only here, on \(branch). "
            + "Do not create another worktree or branch. Inventories, audits and lists go in your final message, "
            + "never in a new file in the repository. "
            + "Keep each background command's handle/PID, log and exit status." + (asks ? " " + askLine : "")
    }

    nonisolated static let askLine = "When you stop to ask, end your last message with a paragraph starting Question:, "
        + "its choices under it, and nothing after them."
}
