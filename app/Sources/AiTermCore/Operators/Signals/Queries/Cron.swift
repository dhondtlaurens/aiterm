import Foundation

/// A schedule's cron expression, parsed by AiTerm itself: five fields (minute, hour, day of month, month, weekday),
/// each a list of `*`, values, ranges and steps, with month and weekday names. When both day fields are restricted
/// (neither starts with `*`) a day matches either one, as Vixie cron does. No seconds, no `@reboot`.
///
/// Times are wall-clock times in the calendar's time zone. A time that a daylight-saving change skips fires at the
/// change itself, the next valid minute; a time that the change repeats fires once, at its first occurrence.
public struct Cron: Equatable, Sendable {
    /// The five fields as written, single-spaced.
    public let expression: String
    let minutes: [Int], hours: [Int], days: Set<Int>, months: Set<Int>, weekdays: Set<Int>
    let daysRestricted: Bool, weekdaysRestricted: Bool

    static let fieldsHelp = "A cron has five fields: minute, hour, day of month, month, weekday."

    public init(_ text: String) throws(QueryRefusal) {
        let fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = fields.first else { throw QueryRefusal(token: "", message: "Enter a cron.") }
        if first.hasPrefix("@") { throw QueryRefusal(token: first, message: "“\(first)” isn’t supported: write the five fields.") }
        guard fields.count == 5 else { throw QueryRefusal(token: fields.count > 5 ? fields[5] : "", message: Self.fieldsHelp) }
        expression = fields.joined(separator: " ")
        minutes = try Field.minute.values(fields[0]).sorted()
        hours = try Field.hour.values(fields[1]).sorted()
        days = try Field.day.values(fields[2])
        months = try Field.month.values(fields[3])
        weekdays = Set(try Field.weekday.values(fields[4]).map { $0 % 7 })
        daysRestricted = !fields[2].hasPrefix("*")
        weekdaysRestricted = !fields[4].hasPrefix("*")
        if !(daysRestricted && weekdaysRestricted), let earliest = days.min(),
           months.allSatisfy({ earliest > Self.longest[$0 - 1] }) {
            let which = months.count == 1 ? "\(Self.monthNames[months.first! - 1]) has" : "None of its months has"
            throw QueryRefusal(token: fields[2], message: "This cron never runs: \(which) no day \(earliest).")
        }
    }

    /// The calendar cron reads its fields on: Gregorian, whatever the Mac's calendar preference, in `calendar`'s time zone.
    public static func gregorian(_ calendar: Calendar) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    /// The first time after `date`.
    public func next(after date: Date, in calendar: Calendar) -> Date? {
        let calendar = Self.gregorian(calendar)
        var day = calendar.startOfDay(for: date)
        for _ in 0..<(366 * 9) {
            if let times = times(on: day, in: calendar) {
                if let found = times.first(where: { $0 > date }) { return found }
            }
            guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = following
        }
        return nil
    }

    /// The most recent time after `lower` and at or before `upper`: the one firing due when several were missed.
    public func latest(atOrBefore upper: Date, after lower: Date, in calendar: Calendar) -> Date? {
        guard upper > lower else { return nil }
        let calendar = Self.gregorian(calendar)
        var day = calendar.startOfDay(for: upper)
        let first = calendar.startOfDay(for: lower)
        while day >= first {
            if let times = times(on: day, in: calendar),
               let found = times.last(where: { $0 <= upper && $0 > lower }) { return found }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
            day = previous
        }
        return nil
    }

    /// The times on the day starting at `day`, ascending; nil when the day does not match.
    private func times(on day: Date, in calendar: Calendar) -> [Date]? {
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
        guard let year = parts.year, let month = parts.month, let date = parts.day, let weekday = parts.weekday,
              months.contains(month) else { return nil }
        let onDay = days.contains(date), onWeekday = weekdays.contains(weekday - 1)
        guard daysRestricted && weekdaysRestricted ? (onDay || onWeekday) : (onDay && onWeekday) else { return nil }
        var out: [Date] = []
        for hour in hours {
            for minute in minutes {
                if let instant = Self.instant(year: year, month: month, day: date, hour: hour, minute: minute, on: day, in: calendar),
                   out.last.map({ $0 < instant }) ?? true { out.append(instant) }
            }
        }
        return out
    }

    private static func instant(year: Int, month: Int, day: Int, hour: Int, minute: Int, on start: Date, in calendar: Calendar) -> Date? {
        let wanted = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        func wall(_ date: Date) -> DateComponents { calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date) }
        guard let date = calendar.date(from: wanted), wall(date) == wanted else {
            // Skipped by a daylight-saving change: it fires at the change.
            // Searched from just before the day starts: where the change skips midnight, the day starts at the change itself.
            guard let change = calendar.timeZone.nextDaylightSavingTimeTransition(after: start.addingTimeInterval(-1)),
                  calendar.isDate(change, inSameDayAs: start) else { return nil }
            return change
        }
        let zone = calendar.timeZone
        let shift = zone.secondsFromGMT(for: date.addingTimeInterval(-43200)) - zone.secondsFromGMT(for: date.addingTimeInterval(43200))
        if shift > 0, wall(date.addingTimeInterval(-Double(shift))) == wanted { return date.addingTimeInterval(-Double(shift)) }
        return date
    }

    // MARK: Reading

    /// The schedule in plain words: "At 09:00 on Monday".
    public var reading: String {
        var sentence = timeReading
        let dayPart = days.count < 31 ? dayReading : nil
        let weekdayPart = weekdays.count < 7 ? weekdayReading : nil
        let joined = [dayPart, weekdayPart].compactMap { $0 }
        if !joined.isEmpty { sentence += " " + joined.joined(separator: daysRestricted && weekdaysRestricted ? " or " : " and ") }
        if months.count < 12 { sentence += " in " + Self.runs(months.sorted()).map { run in
            run.count >= 3 ? "\(Self.monthNames[run[0] - 1]) to \(Self.monthNames[run.last! - 1])" : run.map { Self.monthNames[$0 - 1] }.joined(separator: " and ")
        }.list }
        return sentence
    }

    private var timeReading: String {
        let allMinutes = minutes.count == 60, allHours = hours.count == 24
        if allMinutes && allHours { return "Every minute" }
        if allHours, !allMinutes, minutes.count > 1, minutes[0] == 0,
           minutes == Array(stride(from: 0, to: 60, by: minutes[1])) { return "Every \(minutes[1]) minutes" }
        if allHours, minutes.count == 1 { return "At minute \(minutes[0]) of every hour" }
        if !allMinutes, hours.count * minutes.count <= 4 {
            return "At " + hours.flatMap { hour in minutes.map { String(format: "%02d:%02d", hour, $0) } }.list
        }
        let minutePart = allMinutes ? "Every minute" : "At minute " + minutes.map(String.init).list
        return minutePart + " past hour " + Self.runs(hours).map { $0.count >= 3 ? "\($0[0]) to \($0.last!)" : $0.map(String.init).joined(separator: " and ") }.list
    }

    private var dayReading: String {
        let runs = Self.runs(days.sorted())
        let plural = days.count > 1 ? "days " : "day "
        return "on " + plural + runs.map { $0.count >= 3 ? "\($0[0]) to \($0.last!)" : $0.map(String.init).joined(separator: " and ") }.list + " of the month"
    }

    private var weekdayReading: String {
        let ordered = weekdays.map { $0 == 0 ? 7 : $0 }.sorted()
        if ordered == [1, 2, 3, 4, 5] { return "on weekdays" }
        let name = { (day: Int) in Self.weekdayNames[day % 7] }
        return "on " + Self.runs(ordered).map { run in
            run.count >= 3 ? "\(name(run[0])) to \(name(run.last!))" : run.map(name).joined(separator: " and ")
        }.list
    }

    /// Consecutive values grouped: [1, 2, 3, 5] → [[1, 2, 3], [5]].
    private static func runs(_ values: [Int]) -> [[Int]] {
        var out: [[Int]] = []
        for value in values {
            if let last = out.last?.last, last + 1 == value { out[out.count - 1].append(value) } else { out.append([value]) }
        }
        return out
    }

    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let longest = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    // MARK: Fields

    private enum Field {
        case minute, hour, day, month, weekday

        var bounds: ClosedRange<Int> {
            switch self {
            case .minute: 0...59
            case .hour: 0...23
            case .day: 1...31
            case .month: 1...12
            case .weekday: 0...7
            }
        }

        var names: [String] {
            switch self {
            case .month: ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            case .weekday: ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            default: []
            }
        }

        var help: String {
            switch self {
            case .minute: "a minute: use 0–59"
            case .hour: "an hour: use 0–23"
            case .day: "a day of the month: use 1–31"
            case .month: "a month: use 1–12 or JAN–DEC"
            case .weekday: "a weekday: use 0–6 or MON–SUN"
            }
        }

        func values(_ text: String) throws(QueryRefusal) -> Set<Int> {
            var out = Set<Int>()
            for item in text.split(separator: ",", omittingEmptySubsequences: false).map(String.init) {
                guard !item.isEmpty else { throw QueryRefusal(token: text, message: "“\(text)” has an empty item in its list.") }
                let parts = item.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                var step = 1
                if parts.count == 2 {
                    guard let value = Int(parts[1]) else { throw refusal(parts[1]) }
                    guard value >= 1 else { throw QueryRefusal(token: item, message: "“\(item)” steps by nothing: use a step of 1 or more.") }
                    step = value
                }
                let range: ClosedRange<Int>
                if parts[0] == "*" {
                    range = self == .weekday ? 0...6 : bounds
                } else if let dash = parts[0].firstIndex(of: "-") {
                    let low = try value(String(parts[0][..<dash])), high = try value(String(parts[0][parts[0].index(after: dash)...]))
                    guard low <= high else { throw QueryRefusal(token: item, message: "“\(item)” runs backwards: put the smaller value first.") }
                    range = low...high
                } else {
                    // `a/n` runs from a to the field's end, 7 for a weekday, as Vixie cron reads it: `7/1` is Sunday alone.
                    let single = try value(parts[0])
                    range = single...(parts.count == 2 ? bounds.upperBound : single)
                }
                out.formUnion(stride(from: range.lowerBound, through: range.upperBound, by: step))
            }
            return out
        }

        private func value(_ text: String) throws(QueryRefusal) -> Int {
            if let number = Int(text), bounds.contains(number) { return number }
            if let index = names.firstIndex(of: text.lowercased()) { return index + bounds.lowerBound }
            throw refusal(text)
        }

        private func refusal(_ text: String) -> QueryRefusal {
            QueryRefusal(token: text, message: "“\(text)” isn’t \(help).")
        }
    }
}

private extension Array where Element == String {
    /// "a", "a and b", "a, b and c".
    var list: String {
        count <= 1 ? (first ?? "") : dropLast().joined(separator: ", ") + " and " + last!
    }
}
