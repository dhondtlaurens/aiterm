import Foundation

/// A task on its way out, as its row says it: removed by the person — its window, its worktree,
/// maybe its branch — or closing because its worktree went outside AiTerm; or a removal that
/// stopped short of the row, and why. It is the row's own, so the banner above the list can come
/// and go — replaced by another report, or dismissed — without the row forgetting where it stands.
public enum TaskRemoval: Equatable, Sendable {
    case removing, closing
    /// What the row says in place of its "Window closed" or "Worktree missing". `worktreeRemoved`
    /// is a removal that got past the worktree: the row waits for the person's retry, and checkout
    /// cleanup, which would forget a row whose checkout went, leaves it be.
    case stopped(note: String, worktreeRemoved: Bool)

    /// Still running: the row's window is closing, or gone.
    public var inProgress: Bool {
        if case .stopped = self { false } else { true }
    }

    /// Stopped after its worktree went, so the row is held for a retry.
    public var awaitsRetry: Bool {
        if case .stopped(_, true) = self { true } else { false }
    }
}
