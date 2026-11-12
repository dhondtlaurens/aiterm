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
