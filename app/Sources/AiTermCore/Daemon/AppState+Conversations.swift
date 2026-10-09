import Foundation

public extension AppState {
    /// The workspace with each task's conversations as its window's tabs show them now: every tab in the
    /// task's window whose agent has named its conversation (`SessionInfo.conversationId`), in tab order
    /// — panes of one tab by session id — which is what reopening the window resumes. `only` limits it to
    /// those tasks; nil reads every one.
    ///
    /// A window replaces what was remembered only when every agent tab in it has named its conversation:
    /// a reopened window's agents start one by one, and the first to name its own must not shrink the list
    /// to itself before the others have. A tab closed by hand, its neighbours all named, does shrink it.
    /// A window that shows none leaves what was remembered too: a closed window's tabs are gone, a tab
    /// back at its shell names none, and a reopen must still find them. A windowless task keeps its own.
    /// An id no resume could use — empty, or read as a flag (`TaskConversation.isResumable`) — names none.
    func rememberingConversations(from sessions: [SessionInfo], only: Set<UUID>? = nil) -> AppState {
        var next = self
        for index in next.tasks.indices {
            let task = next.tasks[index]
            guard let window = task.windowId, only?.contains(task.id) ?? true else { continue }
            let agentTabs = sessions
                .filter { $0.windowId == window && $0.agent.agentKind != nil }
                .sorted { ($0.tabIndex, $0.sessionId) < ($1.tabIndex, $1.sessionId) }
            let shown = agentTabs.compactMap { tab -> TaskConversation? in
                guard let agent = tab.agent.agentKind, let id = tab.conversationId, TaskConversation.isResumable(id) else { return nil }
                return TaskConversation(agent: agent, id: id)
            }
            if !shown.isEmpty, shown.count == agentTabs.count, shown != task.conversations {
                next.tasks[index].conversations = shown
            }
        }
        return next
    }
}
