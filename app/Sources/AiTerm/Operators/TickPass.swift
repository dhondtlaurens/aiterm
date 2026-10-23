import Foundation

/// A reconcile tick's pass over the tasks a watcher reads (`BranchWatch`, `ReviewWatcher`): each task in turn, and
/// one pass at a time, so a tick while the last pass still reads starts none. A pass runs to its end: nothing
/// cancels it.
@MainActor
final class TickPass {
    private var running: Task<Void, Never>?
    /// The latest pass, for a test to await.
    private(set) var last: Task<Void, Never>?

    /// Reads `ids`, unless the last pass is still reading or there is nothing to read; `ids` is only asked for then.
    func run(_ ids: @autoclosure () -> [UUID], _ check: @escaping @MainActor (UUID) async -> Void) {
        guard running == nil else { return }
        let ids = ids()
        guard !ids.isEmpty else { return }
        let pass = Task { [weak self] in
            for id in ids { await check(id) }
            self?.running = nil
        }
        running = pass
        last = pass
    }
}
