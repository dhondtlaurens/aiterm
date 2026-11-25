import Foundation

/// A signal's triggers in words, as its heading's tooltip and the signals sheet's row say them: when it starts (a
/// schedule in words, its cron and next run, or the query) and when it is done (a query, the Operator with its
/// guidance, or the person).
public enum SignalSummary {
    /// "Starts: Every weekday at 09:00 (0 9 * * 1-5)" for a schedule, "Starts: labels = operator" otherwise.
    public static func starts(_ signal: Signal) -> String {
        guard signal.isScheduled else { return "Starts: " + signal.start.query }
        return "Starts: " + (signal.start.cron.map { $0.reading + " (" + $0.expression + ")" } ?? signal.start.query)
    }

    /// A schedule's next run, "Next run: 30 Nov 2026 09:00"; nil when there is none.
    public static func nextRun(_ nextRun: Date?, calendar: Calendar = .autoupdatingCurrent) -> String? {
        nextRun.map { "Next run: " + ScheduleDecision.runTime($0, calendar: calendar) }
    }

    /// "Done: The Operator decides (its guidance)", "Done: You decide", or "Done: " and the query.
    public static func done(_ signal: Signal) -> String {
        let guidance = signal.done.description.trimmingCharacters(in: .whitespacesAndNewlines)
        switch signal.done.source {
        case .operator: return "Done: The Operator decides" + (guidance.isEmpty ? "" : " (" + guidance + ")")
        case .person: return "Done: You decide"
        default: return "Done: " + signal.done.query
        }
    }

    /// The three in order: Starts, a schedule's next run when it has one, Done.
    public static func triggers(_ signal: Signal, nextRun next: Date?, calendar: Calendar = .autoupdatingCurrent) -> [String] {
        [starts(signal)] + [nextRun(signal.isScheduled ? next : nil, calendar: calendar)].compactMap { $0 } + [done(signal)]
    }
}
