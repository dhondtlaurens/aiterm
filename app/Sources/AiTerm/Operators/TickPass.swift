import Foundation

/// A cancellable polling task. Each pass returns its next pause, or nil to end. The caller keeps
/// its weak capture and any separately owned pass; this loop retains neither owner during a pause.
@MainActor
struct PollLoop {
    private let task: Task<Void, Never>

    init(interval: Duration, sleepFirst: Bool = false, pass: @escaping @MainActor () async -> Duration?) {
        task = Task { await Self.run(interval: interval, sleepFirst: sleepFirst, pass: pass) }
    }

    func cancel() { task.cancel() }

    /// For a caller that already owns the task and its cancellation, such as a view's watch.
    static func run(interval: Duration, sleepFirst: Bool = false, pass: @MainActor () async -> Duration?) async {
        var pause = interval
        do {
            while !Task.isCancelled {
                if sleepFirst { try await Task.sleep(for: pause) }
                guard let next = await pass() else { return }
                pause = next
                if !sleepFirst { try await Task.sleep(for: pause) }
            }
        } catch { return }
    }
}

/// A reconcile tick's pass over the tasks a watcher reads (`BranchWatch`, `ReviewWatcher`): each task in turn, and
/// one pass at a time, so a tick while the last pass still reads starts none. Stop invalidates the
/// pass before cancelling it; a late completion cannot release a replacement pass's slot.
@MainActor
final class TickPass {
    private var running: Task<Void, Never>?
    private var generation = UUID()
    /// The latest pass, for a test to await.
    private(set) var last: Task<Void, Never>?

    /// Reads `ids`, unless the last pass is still reading or there is nothing to read; `ids` is only asked for then.
    func run(_ ids: @autoclosure () -> [UUID], _ check: @escaping @MainActor (UUID) async -> Void) {
        guard running == nil else { return }
        let ids = ids()
        guard !ids.isEmpty else { return }
        let generation = generation
        let pass = Task { [weak self] in
            for id in ids {
                guard !Task.isCancelled else { return }
                await check(id)
            }
            if self?.generation == generation { self?.running = nil }
        }
        running = pass
        last = pass
    }

    func cancel() {
        generation = UUID()
        running?.cancel()
        running = nil
    }
}
