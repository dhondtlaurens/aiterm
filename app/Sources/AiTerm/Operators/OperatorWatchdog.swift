import Foundation
import AiTermCore

/// Wakes an Operator whose broadcast has gone quiet (broadcast "Broadcast fix", 2026-11-05: A's worker stopped after the
/// Mac slept, nothing woke the Operator, and its stall was found about 2 hours late). It is a safety net under the wakes
/// for news AiTerm recognises (`OperatorWaker`): once a broadcast has had nobody at work and nothing moving for
/// `OperatorTiming.quietWake`, its Operator is woken with one fixed line, `nothing has moved for ten minutes`.
///
/// Once per quiet spell: only a change in what `run_status` shows (`observe`) arms it again. Every event starts the quiet
/// time again: that change, a tool call, a wake line delivered (`touched`), and a check that finds somebody at work or the
/// Operator in its own turn. It fires only for an active broadcast, never while paused, planning, offline, complete or
/// ended. Kept in memory: after AiTerm starts, a broadcast's quiet time starts when it is first seen.
@MainActor
final class OperatorWatchdog {
    /// The wake line's reason, its minutes in words: no wake line carries a digit (`OperatorWaker.isPlain`).
    static let reason = "nothing has moved for ten minutes"

    private struct Watch {
        var since: Date
        var armed = true
        var seen: RunStatus?
    }

    private let now: @MainActor () -> Date
    /// Wakes the run's Operator: the controller's waker, with `reason`.
    var wake: @MainActor (UUID) -> Void
    private var watches: [UUID: Watch] = [:]

    init(now: @escaping @MainActor () -> Date, wake: @escaping @MainActor (UUID) -> Void = { _ in }) {
        self.now = now
        self.wake = wake
    }

    /// What `run_status` would answer now: a change in it (as the waker compares it) starts the quiet time again and arms it.
    func observe(_ status: RunStatus, of run: UUID) {
        let content = OperatorWaker.content(status), at = now()
        guard var watch = watches[run] else { watches[run] = Watch(since: at, seen: content); return }
        guard watch.seen != content else { return }
        watch.seen = content
        watch.since = at
        watch.armed = true
        watches[run] = watch
    }

    /// A tool call or a wake line delivered: the quiet time starts again, and the watch stays as armed as it was.
    func touched(_ run: UUID) {
        let at = now()
        if watches[run] == nil { watches[run] = Watch(since: at) } else { watches[run]?.since = at }
    }

    /// The reconcile tick's look: wakes the Operator when the broadcast has been quiet long enough.
    func check(_ run: UUID, status: RunStatus, state: OperatorRunState, operatorWorking: Bool) {
        let at = now()
        guard state == .active else { touched(run); return }
        guard var watch = watches[run] else { watches[run] = Watch(since: at, seen: OperatorWaker.content(status)); return }
        if operatorWorking || Self.atWork(status) {
            watch.since = at
            watches[run] = watch
            return
        }
        guard watch.armed, at.timeIntervalSince(watch.since) >= OperatorTiming.quietWake else { return }
        watch.armed = false
        watches[run] = watch
        wake(run)
    }

    func forget(_ run: UUID) { watches[run] = nil }

    /// Somebody at work, on any of a task's tabs: a first worker working or opening, an extra tab (a reviewer, an
    /// `open_tab`) working or opening, a job left running in the background, a test run queued or running.
    static func atWork(_ status: RunStatus) -> Bool {
        let working: Set<RunStatus.LiveState> = [.working, .workingQuiet]
        return !status.obligations.background.isEmpty || status.tasks.contains { task in
            task.live.map(working.contains) == true || task.opening == true
                || task.tabs?.contains { $0.opening || $0.live.map(working.contains) == true } == true
                || task.background?.isEmpty == false
                || task.testActivities?.contains(where: \.isActive) == true
        }
    }
}
