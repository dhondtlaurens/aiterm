import Foundation

/// Which scheduled runs are due now, the pure rule the scheduler applies on each Operator tick.
///
/// Per runnable scheduled signal, the latest time of its cron after both its cursor (the last time fired or skipped) and
/// its `scheduledFrom`, and at or before now, is due: older missed times are dropped, and a time is never due twice. A
/// due time is skipped, with its reason, while the signal's previous run is unfinished or its project is gone. Either
/// way the cursor moves to it. While a signal may not act (an Operator signal while the Operator is paused, any while it
/// is stopped), nothing of it is due and its cursor does not move, so the latest time missed meanwhile runs once it may.
public enum ScheduleDecision {
    public struct Due: Equatable, Sendable {
        public var signal: UUID, run: SignalRunRef, project: UUID
        public init(signal: UUID, run: SignalRunRef, project: UUID) { self.signal = signal; self.run = run; self.project = project }
    }
    public struct Skip: Equatable, Sendable {
        public var signal: UUID, run: SignalRunRef, reason: String
        public init(signal: UUID, run: SignalRunRef, reason: String) { self.signal = signal; self.run = run; self.reason = reason }
    }
    public struct Outcome: Equatable, Sendable {
        public var due: [Due] = [], skipped: [Skip] = []
        /// The cursors that move, by signal.
        public var cursors: [UUID: Date] = [:]
    }

    static let unfinished = "The last run is still unfinished."
    public static let projectGone = "Its project is no longer in AiTerm."

    /// `tasks` are the sidebar's, `archive` the archived ones; `pending` names the signals with a run queued or being
    /// created that has no task yet.
    public static func decide(signals: [Signal], cursors: [UUID: Date], tasks: [TaskItem], archive: [TaskItem], projects: [Project],
                              now: Date, calendar: Calendar, mayAct: (Signal) -> Bool, pending: Set<UUID> = []) -> Outcome {
        var outcome = Outcome()
        for signal in signals where signal.isScheduled && signal.isRunnable && mayAct(signal) {
            guard let cron = signal.start.cron,
                  let at = cron.latest(atOrBefore: now, after: lowerBound(of: signal, cursor: cursors[signal.id]), in: calendar) else { continue }
            let run = SignalRunRef(signal: signal.id, at: at)
            outcome.cursors[signal.id] = at
            if previousRunUnfinished(signal.id, tasks: tasks, archive: archive, pending: pending) {
                outcome.skipped.append(Skip(signal: signal.id, run: run, reason: unfinished))
            } else if let project = signal.start.project, projects.contains(where: { $0.id == project }) {
                outcome.due.append(Due(signal: signal.id, run: run, project: project))
            } else {
                outcome.skipped.append(Skip(signal: signal.id, run: run, reason: projectGone))
            }
        }
        return outcome
    }

    /// The signal's next time after now and after its cursor and `scheduledFrom`; nil when it never runs again.
    public static func nextRun(of signal: Signal, cursor: Date?, now: Date, calendar: Calendar) -> Date? {
        guard let cron = signal.start.cron else { return nil }
        return cron.next(after: max(now, lowerBound(of: signal, cursor: cursor)), in: calendar)
    }

    /// Whether one of `signal`'s runs is unfinished: a task that started from one is still the Operator's and
    /// unfinished, whichever signal's stage it runs now; a project signal's run task, in the sidebar and not taken over,
    /// has not reached its Done; or a run is in `pending`, queued or being created with no task yet.
    public static func previousRunUnfinished(_ signal: UUID, tasks: [TaskItem], archive: [TaskItem], pending: Set<UUID> = []) -> Bool {
        if pending.contains(signal) { return true }
        if (tasks + archive).contains(where: { task in
            guard let record = task.signalTask, record.scheduledRun?.signal == signal else { return false }
            return !record.isFinished
        }) { return true }
        return tasks.contains { task in
            guard task.signalTask == nil, !task.takenOver, let origin = task.signalOrigin, case .run(let run) = origin.item else { return false }
            return run.signal == signal && origin.doneAt == nil
        }
    }

    /// A run's task title: `Weekly dependency update · 23 Nov 2026 09:00`, the scheduled time on `calendar`.
    public static func runTitle(signalName: String, at: Date, calendar: Calendar) -> String {
        signalName + " · " + runTime(at, calendar: calendar)
    }

    /// A scheduled time as runs name it: `23 Nov 2026 09:00`.
    public static func runTime(_ at: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Cron.gregorian(calendar); formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM yyyy HH:mm"
        return formatter.string(from: at)
    }

    private static func lowerBound(of signal: Signal, cursor: Date?) -> Date {
        max(cursor ?? .distantPast, signal.scheduledFrom ?? signal.createdAt)
    }
}
