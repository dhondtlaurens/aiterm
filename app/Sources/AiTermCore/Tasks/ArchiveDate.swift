import Foundation

/// When a row was archived, as the Archive sheet's group headings say it: "Today", "Yesterday", "This week", then the
/// month ("October"), with its year once it is another year's ("September 2025"). Rows are newest first, so the groups
/// come in this order too.
public enum ArchiveDate {
    public static func group(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return "This week" }
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "LLLL" : "LLLL yyyy"
        return formatter.string(from: date)
    }
}
