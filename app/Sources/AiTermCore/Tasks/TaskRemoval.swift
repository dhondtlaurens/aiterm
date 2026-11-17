import Foundation

/// A task on its way out, as its row says it: removed by the person — its window, its worktree,
/// maybe its branch — or closing because its worktree went outside AiTerm; or a removal that
/// stopped before anything was deleted, and why. It is the row's own, so the banner above the list
/// can come and go — replaced by another report, or dismissed — without the row forgetting where it
/// stands.
public enum TaskRemoval: Equatable, Sendable {
    case removing, closing, archiving
    /// What the row says in place of its "Worktree missing" while the banner about the stop is up.
    case stopped(note: String)

    /// Still running: the row's window is closing, or gone.
    public var inProgress: Bool {
        if case .stopped = self { false } else { true }
    }
}
