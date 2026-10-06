import Foundation

/// Work of which only the latest run counts. Starting a run cancels the one before it, and a run asks
/// `isCurrent` after each `await`: cancellation does not stop code between suspension points, so a
/// superseded run that went on could still write over its successor's result. A run is let go once
/// it ends, unless a newer one has taken its place.
@MainActor
final class LatestTask {
    /// The run in flight, if any.
    private(set) var task: Task<Void, Never>?
    /// Moves on with every run and every `cancel()`, so work started before either can tell.
    private(set) var generation = 0

    /// Cancels the run in flight and starts `body` in its place. `isCurrent` says whether this run is
    /// still the latest and not cancelled.
    @discardableResult
    func run(_ body: @escaping @MainActor (_ isCurrent: @escaping @MainActor () -> Bool) async -> Void) -> Task<Void, Never> {
        cancel()
        let generation = generation
        let task = Task {
            defer { if generation == self.generation { self.task = nil } }
            await body { !Task.isCancelled && generation == self.generation }
        }
        self.task = task
        return task
    }

    /// Cancels the run in flight, if any, and makes it stale.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }
}
