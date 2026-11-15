import Foundation
import AiTermCore

@MainActor enum AutomaticCleanup {
    static let unsavedWork = "Not closed: its worktree has uncommitted or untracked files. Remove it yourself once they are safe."
    static func isDriving(_ task: TaskItem, in live: LiveSessions) -> Bool {
        task.workerTabs(in: live.sessions).contains { $0.session?.yourPrompt != nil }
    }
}
