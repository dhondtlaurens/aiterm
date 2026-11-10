import Foundation
@testable import AiTermCore

/// The rows and tabs a test builds, with every field it does not care about filled in once, here.
extension TaskItem {
    /// A task in `project`, with no worktree of its own on disk unless `worktreePath` names one.
    static func stub(in project: Project, title: String = "Work", branch: String? = nil, worktreePath: String? = nil,
                     kind: TaskKind = .task, windowId: String? = nil) -> TaskItem {
        let branch = branch ?? "feat/\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"
        return .make(project: project.id, title: title, branch: branch,
                     worktreePath: worktreePath ?? project.path + "/.worktrees/" + branch, kind: kind, agent: .codex,
                     model: "model", windowId: windowId)
    }
}

extension SessionInfo {
    /// A tab in `window`, tagged with `task` (or `terminal`) when there is one and working in the task's worktree.
    static func stub(_ sessionId: String = "s", window: String, task: TaskItem? = nil, terminal: TerminalItem? = nil, state: SessionState = .idle,
                     agent: SessionAgent = .codex) -> SessionInfo {
        var session = SessionInfo.make(sessionId, window: window, task: task?.id, agent: agent, state: state,
                                       cwd: task?.worktreePath ?? "/")
        session.terminalId = terminal?.id.uuidString
        return session
    }
}
