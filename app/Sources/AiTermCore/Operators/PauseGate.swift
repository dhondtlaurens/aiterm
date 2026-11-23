import Foundation

/// Holds a window the Operator opens on its own until you have paused: no key and no click for `pause`
/// seconds while iTerm2 or AiTerm is in front. iTerm2 makes a brand-new window key and front even when it is
/// asked for unselected, so one opened while you type takes your keys and covers your window; one opened in a
/// pause is ordered back behind your window by the daemon before you type again. With another app in front
/// nothing in iTerm2 or AiTerm takes your keys, so nothing waits. A background tab in an open window is
/// neither selected nor raised by iTerm2 and never needs the gate.
public struct PauseGate: Sendable {
    /// Seconds without a key or a click that count as a pause.
    public let pause: TimeInterval
    /// Seconds since your last key or click, or nil while neither iTerm2 nor AiTerm is the frontmost app.
    private let idle: @MainActor @Sendable () -> TimeInterval?
    private let sleep: @MainActor @Sendable (TimeInterval) async throws -> Void
    /// The one turn in which a window the Operator opens on its own is asked for, shared by every copy of this gate.
    public let turn = WindowTurn()

    public init(pause: TimeInterval = OperatorTiming.pauseBeforeOpening,
                idle: @escaping @MainActor @Sendable () -> TimeInterval?,
                sleep: @escaping @MainActor @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.pause = pause; self.idle = idle; self.sleep = sleep
    }

    /// A gate that never waits, with a turn of its own: what tests and a missing input source get.
    public static var never: PauseGate { PauseGate(idle: { nil }) }

    /// Seconds still to wait for a pause; 0 when you have paused or are in another app.
    @MainActor private var remaining: TimeInterval {
        guard let idle = idle() else { return 0 }
        return max(0, pause - idle)
    }
    /// Whether a window may open now.
    @MainActor public var isQuiet: Bool { remaining == 0 }

    /// Returns once you have paused, however long that takes; a key or a click meanwhile starts the pause
    /// again. A cancelled task returns at once, unpaused, and so does one whose `waiting` turned false (checked
    /// at least once per pause): its caller checks its own authority next.
    @MainActor public func quiet(while waiting: @MainActor () -> Bool = { true }) async {
        while waiting(), case let wait = remaining, wait > 0 {
            do { try await sleep(wait) } catch { return }
        }
    }
}

/// Windows the Operator opens on its own, one at a time. A window is asked for only inside the turn, after a last look
/// at your pause there: windows released by the same pause would otherwise queue in the daemon and open after you
/// went back to typing. The next turn starts once the window before has been made and your window has its focus back.
@MainActor public final class WindowTurn {
    private var taken = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    nonisolated public init() {}
    /// Whether a window waits for the turn while another holds it.
    public var isWaitedOn: Bool { !waiting.isEmpty }

    /// Runs `body` alone, after those that asked before; the turn passes on when it returns or throws.
    public func take<Result>(_ body: @MainActor () async throws -> Result) async rethrows -> Result {
        if taken { await withCheckedContinuation { waiting.append($0) } } else { taken = true }
        defer { if waiting.isEmpty { taken = false } else { waiting.removeFirst().resume() } }
        return try await body()
    }
}
