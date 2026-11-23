import Foundation
import Testing
@testable import AiTermCore

/// A schedule's cron: five fields, AiTerm's own parser, times on the Mac's calendar.
@Suite struct CronTests {
    static let brussels: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Brussels")!
        return calendar
    }()

    static func at(_ text: String, _ calendar: Calendar = brussels) -> Date {
        let parts = text.split(whereSeparator: { "- :".contains($0) }).map { Int($0)! }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4]))!
    }

    static func wall(_ date: Date, _ calendar: Calendar = brussels) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    func next(_ cron: String, after: String, count: Int = 1) throws -> [String] {
        let parsed = try Cron(cron)
        var from = Self.at(after), out: [String] = []
        for _ in 0..<count {
            guard let date = parsed.next(after: from, in: Self.brussels) else { break }
            out.append(Self.wall(date)); from = date
        }
        return out
    }

    // MARK: parsing

    @Test(arguments: ["0 9 * * 1", "*/15 * * * *", "30 8 * * 1-4", "0 0 1,15 * *", "0 9 * jan,jul mon-fri",
                      "5-55/10 6-18/2 * * *", "0 12 * * 7", "0 0 31 * *",
                      "  0   9 * *   SUN  ", "0 9 * * 5/1"])
    func acceptsStandardFields(_ text: String) throws {
        #expect(throws: Never.self) { try Cron(text) }
    }

    struct Refused: Sendable, CustomTestStringConvertible {
        var text: String, token: String, message: String
        var testDescription: String { text }
    }

    static let refused: [Refused] = [
        Refused(text: "0 9 * * Mo", token: "Mo", message: "“Mo” isn’t a weekday: use 0–6 or MON–SUN."),
        Refused(text: "0 9 * * 1 2", token: "2", message: "A cron has five fields: minute, hour, day of month, month, weekday."),
        Refused(text: "0 9 * *", token: "", message: "A cron has five fields: minute, hour, day of month, month, weekday."),
        Refused(text: "", token: "", message: "Enter a cron."),
        Refused(text: "60 9 * * *", token: "60", message: "“60” isn’t a minute: use 0–59."),
        Refused(text: "0 24 * * *", token: "24", message: "“24” isn’t an hour: use 0–23."),
        Refused(text: "0 9 0 * *", token: "0", message: "“0” isn’t a day of the month: use 1–31."),
        Refused(text: "0 9 * 13 *", token: "13", message: "“13” isn’t a month: use 1–12 or JAN–DEC."),
        Refused(text: "0 9 * * 8", token: "8", message: "“8” isn’t a weekday: use 0–6 or MON–SUN."),
        Refused(text: "*/0 * * * *", token: "*/0", message: "“*/0” steps by nothing: use a step of 1 or more."),
        Refused(text: "0 9 * * 5-1", token: "5-1", message: "“5-1” runs backwards: put the smaller value first."),
        Refused(text: "@reboot", token: "@reboot", message: "“@reboot” isn’t supported: write the five fields."),
        Refused(text: "0 0 9 * * 1", token: "1", message: "A cron has five fields: minute, hour, day of month, month, weekday."),
        Refused(text: "0 9 30 2 *", token: "30", message: "This cron never runs: February has no day 30."),
        Refused(text: "0 9 ,1 * *", token: ",1", message: "“,1” has an empty item in its list."),
    ]

    @Test(arguments: refused) func refusesWithTheTokenAtFault(_ row: Refused) {
        #expect(throws: QueryRefusal(token: row.token, message: row.message)) { try Cron(row.text) }
    }

    /// A weekday step from a value runs to 7, Sunday: `5/1` is Friday to Sunday, and `7/1` Sunday alone, never a trap.
    @Test func aWeekdayStepRunsThroughSunday() throws {
        #expect(try Cron("0 9 * * 5/1").weekdays == [5, 6, 0])
        #expect(try Cron("0 9 * * 7/1").weekdays == [0])
        #expect(try Cron("0 9 * * SUN/2").weekdays == [0, 2, 4, 6])
    }

    /// The Mac's calendar preference never changes a cron: its fields are Gregorian, in the calendar's time zone.
    @Test func aNonGregorianCalendarStillRunsEveryDay() throws {
        var hebrew = Calendar(identifier: .hebrew); hebrew.timeZone = Self.brussels.timeZone
        let cron = try Cron("0 9 * * *")
        var from = Self.at("2026-11-23 10:00"), days: [String] = []
        for _ in 0..<3 { guard let next = cron.next(after: from, in: hebrew) else { break }; days.append(Self.wall(next)); from = next }
        #expect(days == ["2026-11-24 09:00", "2026-11-25 09:00", "2026-11-26 09:00"])
        #expect(ScheduleDecision.runTime(Self.at("2026-11-23 09:00"), calendar: hebrew) == "23 Nov 2026 09:00")
    }

    @Test func sundayIsBothZeroAndSeven() throws {
        #expect(try next("0 12 * * 0", after: "2026-11-23 00:00") == ["2026-11-29 12:00"])
        #expect(try next("0 12 * * 7", after: "2026-11-23 00:00") == ["2026-11-29 12:00"])
        #expect(try next("0 12 * * SUN", after: "2026-11-23 00:00") == ["2026-11-29 12:00"])
    }

    // MARK: next

    @Test func everyMondayAtNine() throws {
        // 23 Nov 2026 is a Monday.
        #expect(try next("0 9 * * 1", after: "2026-11-23 08:59", count: 3)
                == ["2026-11-23 09:00", "2026-11-30 09:00", "2026-12-07 09:00"])
        #expect(try next("0 9 * * 1", after: "2026-11-23 09:00") == ["2026-11-30 09:00"])
    }

    @Test func stepsRangesAndNames() throws {
        #expect(try next("*/20 9-10 * * *", after: "2026-11-23 09:10", count: 4)
                == ["2026-11-23 09:20", "2026-11-23 09:40", "2026-11-23 10:00", "2026-11-23 10:20"])
        #expect(try next("30 8 * * mon-thu", after: "2026-11-26 09:00", count: 2)
                == ["2026-11-30 08:30", "2026-12-01 08:30"])
        #expect(try next("0 0 1 jan,jul *", after: "2026-11-23 00:00", count: 2)
                == ["2027-01-01 00:00", "2027-07-01 00:00"])
        #expect(try next("0 6/8 * * *", after: "2026-11-23 07:00", count: 3)
                == ["2026-11-23 14:00", "2026-11-23 22:00", "2026-11-24 06:00"])
    }

    @Test func monthEndsAndLeapDays() throws {
        #expect(try next("0 9 31 * *", after: "2026-11-23 00:00", count: 3)
                == ["2026-12-31 09:00", "2027-01-31 09:00", "2027-03-31 09:00"])
        #expect(try next("0 9 29 2 *", after: "2026-11-23 00:00") == ["2028-02-29 09:00"])
    }

    @Test func bothDayFieldsRestrictedMatchEither() throws {
        // Vixie: the 1st of the month or any Friday.
        #expect(try next("0 9 1 * 5", after: "2026-11-23 00:00", count: 3)
                == ["2026-11-27 09:00", "2026-12-01 09:00", "2026-12-04 09:00"])
        // A day field starting with * makes both fields apply: odd days that are Fridays.
        #expect(try next("0 9 */2 * 5", after: "2026-11-23 00:00", count: 2)
                == ["2026-11-27 09:00", "2026-12-11 09:00"])
    }

    @Test func aTimeSpringForwardSkipsFiresAtTheNextValidMinute() throws {
        // Europe/Brussels jumps from 02:00 to 03:00 on 28 Mar 2027.
        let fires = try next("30 2 * * *", after: "2027-03-27 03:00", count: 3)
        #expect(fires == ["2027-03-28 03:00", "2027-03-29 02:30", "2027-03-30 02:30"])
        // Every minute of the skipped hour lands on one instant, once.
        #expect(try next("* 2 28 3 *", after: "2027-03-28 01:58", count: 3)
                == ["2027-03-28 03:00", "2028-03-28 02:00", "2028-03-28 02:01"])
    }

    /// Where the change skips midnight itself (America/Santiago, 5 Sep 2027), a midnight run fires at the change, 01:00.
    @Test func aChangeThatSkipsMidnightStillFiresThatDay() throws {
        var santiago = Calendar(identifier: .gregorian); santiago.timeZone = TimeZone(identifier: "America/Santiago")!
        let start = santiago.date(from: DateComponents(year: 2027, month: 9, day: 4, hour: 12))!
        let next = try #require(try Cron("0 0 * * *").next(after: start, in: santiago))
        #expect(Self.wall(next, santiago) == "2027-09-05 01:00")
    }

    @Test func aTimeFallBackRepeatsFiresOnce() throws {
        // Europe/Brussels goes from 03:00 back to 02:00 on 31 Oct 2027.
        let cron = try Cron("30 2 * * *")
        let first = try #require(cron.next(after: Self.at("2027-10-31 00:00"), in: Self.brussels))
        #expect(Self.brussels.timeZone.secondsFromGMT(for: first) == 7200)
        let second = try #require(cron.next(after: first, in: Self.brussels))
        #expect(Self.wall(second) == "2027-11-01 02:30")
        // Hourly: the repeated 02:00 does not fire a second time.
        let hourly = try Cron("0 * * * *")
        let two = try #require(hourly.next(after: Self.at("2027-10-31 01:30"), in: Self.brussels))
        let three = try #require(hourly.next(after: two, in: Self.brussels))
        #expect(three.timeIntervalSince(two) == 7200)
        #expect(Self.wall(three) == "2027-10-31 03:00")
    }

    // MARK: latest

    @Test func latestIsTheMostRecentTimeInTheWindow() throws {
        let cron = try Cron("0 9 * * 1")
        let now = Self.at("2026-12-08 10:00")
        // Two Mondays missed since the cursor: only the latest.
        #expect(cron.latest(atOrBefore: now, after: Self.at("2026-11-23 09:00"), in: Self.brussels).map { Self.wall($0) }
                == "2026-12-07 09:00")
        // The bound is exclusive: a time already fired is not due again.
        #expect(cron.latest(atOrBefore: now, after: Self.at("2026-12-07 09:00"), in: Self.brussels) == nil)
        // The upper bound is inclusive.
        #expect(cron.latest(atOrBefore: Self.at("2026-12-07 09:00"), after: Self.at("2026-12-01 00:00"), in: Self.brussels)
                .map { Self.wall($0) } == "2026-12-07 09:00")
        #expect(cron.latest(atOrBefore: Self.at("2026-12-07 08:59"), after: Self.at("2026-12-01 00:00"), in: Self.brussels) == nil)
    }

    @Test func latestAcrossSpringForward() throws {
        let cron = try Cron("30 2 * * *")
        #expect(cron.latest(atOrBefore: Self.at("2027-03-28 04:00"), after: Self.at("2027-03-27 03:00"), in: Self.brussels)
                .map { Self.wall($0) } == "2027-03-28 03:00")
    }

    // MARK: reading

    @Test(arguments: [
        ("0 9 * * 1", "At 09:00 on Monday"),
        ("30 8 * * 1-4", "At 08:30 on Monday to Thursday"),
        ("0 9 * * 1-5", "At 09:00 on weekdays"),
        ("*/15 * * * *", "Every 15 minutes"),
        ("* * * * *", "Every minute"),
        ("0 * * * *", "At minute 0 of every hour"),
        ("0 0 1 * *", "At 00:00 on day 1 of the month"),
        ("0 9 1 * 5", "At 09:00 on day 1 of the month or on Friday"),
        ("0 9 * jan,jul *", "At 09:00 in January and July"),
        ("0 9,17 * * *", "At 09:00 and 17:00"),
    ])
    func readsAsASentence(_ text: String, _ reading: String) throws {
        #expect(try Cron(text).reading == reading)
    }
}
