import Foundation

public extension AppState {
    /// The workspace with each task's conversations as its window's tabs show them now: every tab in the
    /// task's window whose agent has named its conversation (`SessionInfo.conversationId`), in tab order
    /// — panes of one tab by session id — which is what reopening the window resumes. `only` limits it to
    /// those tasks; nil reads every one.
    ///
    /// A window that shows none leaves what was remembered: a closed window's tabs are gone, a tab back
    /// at its shell names none, and a reopen must still find them. A windowless task keeps its own.
    func rememberingConversations(from sessions: [SessionInfo], only: Set<UUID>? = nil) -> AppState {
        var next = self
        for index in next.tasks.indices {
            let task = next.tasks[index]
            guard let window = task.windowId, only?.contains(task.id) ?? true else { continue }
            let shown = sessions
                .filter { $0.windowId == window }
                .sorted { ($0.tabIndex, $0.sessionId) < ($1.tabIndex, $1.sessionId) }
                .compactMap { tab -> TaskConversation? in
                    guard let agent = tab.agent.agentKind, let id = tab.conversationId, !id.isEmpty else { return nil }
                    return TaskConversation(agent: agent, id: id)
                }
            if !shown.isEmpty, shown != task.conversations { next.tasks[index].conversations = shown }
        }
        return next
    }
}
