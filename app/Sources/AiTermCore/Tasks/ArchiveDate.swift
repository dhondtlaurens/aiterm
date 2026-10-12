import Foundation

/// When a row was archived, as the Archive sheet's rows say it: relative today ("2 hr ago"),
/// "yesterday", then the day ("9 Oct"), with the year once it is another year's.
public enum ArchiveDate {
    public static func label(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            formatter.calendar = calendar
            formatter.locale = locale
            return formatter.localizedString(for: date, relativeTo: now)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return date.formatted(style)
    }
}
