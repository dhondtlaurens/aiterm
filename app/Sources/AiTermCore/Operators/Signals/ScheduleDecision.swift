import Foundation

/// Which scheduled runs are due now, the pure rule the scheduler applies on each Operator tick.
///
/// Per runnable scheduled signal, the latest time of its cron after both its cursor (the last time fired or skipped) and
/// its `scheduledFrom`, and at or before now, is due: older missed times are dropped, and a time is never due twice. A
/// due time is skipped, with its reason, while the signal's previous run is unfinished or its project is gone. Either
/// way the cursor moves to it. While the Operator may not act (paused or stopped), nothing is due and no cursor moves,
/// so the latest time missed meanwhile runs once it may.
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
    static let projectGone = "Its project is no longer in AiTerm."

    public static func decide(signals: [Signal], cursors: [UUID: Date], tasks: [TaskItem], projects: [Project],
                              now: Date, calendar: Calendar, mayAct: Bool) -> Outcome {
        var outcome = Outcome()
        guard mayAct else { return outcome }
        for signal in signals where signal.isScheduled && signal.isRunnable {
            guard let cron = signal.start.cron,
                  let at = cron.latest(atOrBefore: now, after: lowerBound(of: signal, cursor: cursors[signal.id]), in: calendar) else { continue }
            let run = SignalRunRef(signal: signal.id, at: at)
            outcome.cursors[signal.id] = at
            if previousRunUnfinished(signal.id, in: tasks) {
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

    /// Whether a task that started from one of `signal`'s runs is still the Operator's and unfinished, whichever signal's
    /// stage it runs now.
    public static func previousRunUnfinished(_ signal: UUID, in tasks: [TaskItem]) -> Bool {
        tasks.contains { task in
            guard let record = task.signalTask, record.scheduledRun?.signal == signal else { return false }
            return !record.isFinished
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
