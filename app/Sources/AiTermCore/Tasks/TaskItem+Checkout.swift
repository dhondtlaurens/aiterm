import Foundation

public extension TaskItem {
    /// Whether the row has a worktree to scan, open a window in or remove. Every task made in a sheet
    /// has one from its first save; an operator's planned or queued task gets its worktree only when
    /// AiTerm starts it, and until then its path is empty.
    var hasCheckout: Bool { !worktreePath.isEmpty }
}
