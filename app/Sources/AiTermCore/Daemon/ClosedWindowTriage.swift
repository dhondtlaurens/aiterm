import Foundation

/// Whether a task window iTerm2 reports closed was closed by the person, on its own, and so whether
/// Remove's question follows it (`WindowReconciler`). iTerm2 cannot say who closed a window, and a
/// quit, a crash or a restart closes windows too, so a task's close is held for `hold` and dropped when
/// what surrounds it says iTerm2 was going away:
///
/// - iTerm2 leaves the synced state while it is held: a quit closes its windows, then its API socket.
/// - another window closes less than `hold` before or after it: a quit closes every window in a burst.
/// - it arrives before the snapshot that follows a (re)connection: the daemon announces the windows
///   iTerm2 lost while it was away on its first tick back, which runs before that snapshot's reply.
///
/// A value, told the time by its caller, so the rule is tested without waiting on a clock.
public struct ClosedWindowTriage: Equatable, Sendable {
    /// How long a task's close waits before it is asked about.
    public static let hold: Duration = .seconds(1)

    private struct Held: Equatable, Sendable {
        let task: UUID
        let at: ContinuousClock.Instant
    }

    /// The task closes waiting out their hold, oldest first.
    private var held: [Held] = []
    /// When the last window of any kind closed.
    private var lastClose: ContinuousClock.Instant?
    /// Whether iTerm2 has been connected without a break since the last connected snapshot.
    private var synced = false

    public init() {}

    /// Whether a close is waiting out its hold.
    public var isHolding: Bool { !held.isEmpty }

    /// True on a connected snapshot; false on `iterm.connected` (until its snapshot), `iterm.disconnected`,
    /// `iterm.auth_failed` and a disconnected snapshot — which also drops every close held.
    public mutating func itermSynced(_ synced: Bool) {
        self.synced = synced
        if !synced { held = [] }
    }

    /// A window closed at `now`; `task` is the task whose window it was, nil for any other window — or
    /// for a task whose close is someone else's (a removal's, the checkout cleanup's).
    public mutating func windowClosed(task: UUID?, at now: ContinuousClock.Instant) {
        defer { lastClose = now }
        if let last = lastClose, now - last < Self.hold {
            held = []
            return
        }
        guard synced, let task else { return }
        held.append(Held(task: task, at: now))
    }

    /// The tasks whose close has been held its full `hold` with nothing after it, taken out: each is
    /// asked about once.
    public mutating func due(at now: ContinuousClock.Instant) -> [UUID] {
        let due = held.filter { now - $0.at >= Self.hold }
        held.removeAll { now - $0.at >= Self.hold }
        return due.map(\.task)
    }
}
