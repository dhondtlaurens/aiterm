import Foundation
import AiTermCore

/// The rows and tabs a test builds, with every field it does not care about filled in once, here.
extension TaskItem {
    /// A task in `project`, with no worktree of its own on disk unless `worktreePath` names one.
    static func stub(in project: Project, title: String = "Work", branch: String? = nil, worktreePath: String? = nil,
                     kind: TaskKind? = nil, windowId: String? = nil) -> TaskItem {
        let branch = branch ?? "feat/\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"
        return TaskItem(id: UUID(), projectId: project.id, title: title, branch: branch,
                        worktreePath: worktreePath ?? project.path + "/.worktrees/" + branch, baseBranch: "main", jira: nil,
                        kind: kind, agent: .codex, model: "model", reasoning: nil, firstPrompt: nil, appendTicket: false,
                        createdAt: Date(timeIntervalSince1970: 0), windowId: windowId)
    }
}

extension SessionInfo {
    /// A tab in `window`, tagged with `task` when there is one and working in its worktree. Decoded
    /// from the daemon's wire form, because `SessionInfo` has no public memberwise initializer and
    /// this library sees only what Core makes public.
    static func stub(_ sessionId: String = "s", window: String, task: TaskItem? = nil, state: SessionState = .idle,
                     agent: SessionAgent = .codex) -> SessionInfo {
        var wire: [String: Any] = ["sessionId": sessionId, "windowId": window, "tabIndex": 0, "agent": agent.rawValue,
                                   "state": state.rawValue, "title": "", "cwd": task?.worktreePath ?? "/"]
        if let task { wire["taskId"] = task.id.uuidString }
        // A literal that fails to decode is a mistake in this file, not a case a test handles.
        return try! JSONDecoder().decode(SessionInfo.self, from: JSONSerialization.data(withJSONObject: wire))
    }
}
