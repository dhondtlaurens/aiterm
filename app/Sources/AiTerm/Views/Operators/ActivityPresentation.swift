import Foundation
import AiTermCore

/// The calendar grouping and headings the Activity view draws. Kept with its presentation,
/// independent of the expanded row. Replacement entries, the full calendar and the
/// current calendar day invalidate it, including midnight, time-zone and locale changes.
@MainActor
final class ActivityPresentation {
    struct Day: Identifiable {
        let start: Date
        let entries: [ActivityEntry]
        let title: String
        var id: Date { start }
    }

    private struct Inputs: Equatable {
        let entries: [ActivityEntry]
        let calendar: Calendar
        let today: Date
    }
    private var inputs: Inputs?
    private var days: [Day] = []

    func layout(_ entries: [ActivityEntry], now: Date, calendar: Calendar) -> [Day] {
        let next = Inputs(entries: entries, calendar: calendar, today: calendar.startOfDay(for: now))
        guard next != inputs else { return days }
        days = BroadcastActivityView.days(entries, calendar: calendar).map {
            Day(start: $0.start, entries: $0.entries,
                title: BroadcastActivityView.dayTitle($0.start, now: now, calendar: calendar))
        }
        inputs = next
        return days
    }
}
