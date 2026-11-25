import Foundation
import Testing
@testable import AiTermCore

@Suite struct SignalReadIssuesTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let signal = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    let other = UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!

    /// Every failure counts, whatever its reason; the third in a row raises the banner, once for the streak.
    @Test func everyFailureCountsAndTheThirdInARowRaisesTheBannerOnce() {
        var issues = SignalReadIssues()
        let first = issues.fail(signal, "Timed out.", at: t0)
        #expect(!first && issues.issue(for: signal) == .init(signal: signal, text: "Timed out.", since: t0, attempts: 1))
        let second = issues.fail(signal, "Refused.", at: t0 + 60)
        let third = issues.fail(signal, "Refused.", at: t0 + 120)
        let fourth = issues.fail(signal, "Refused.", at: t0 + 180)
        #expect(!second && third && !fourth, "The third failure raises the banner, once for the streak.")
        #expect(issues.issue(for: signal) == .init(signal: signal, text: "Refused.", since: t0, attempts: 4, raised: true, last: t0 + 180))
    }

    /// A good read clears the signal's issue and says whether its banner was up; a new streak counts from one again.
    @Test func aGoodReadClearsTheIssueAndANewStreakStartsAgain() {
        var issues = SignalReadIssues()
        for at in 0..<3 { issues.fail(signal, "Timed out.", at: t0 + Double(at)) }
        let cleared = issues.succeed(signal)
        #expect(cleared?.raised == true)
        #expect(issues.issue(for: signal) == nil && issues.current.isEmpty)
        let again = issues.succeed(signal)
        #expect(again == nil, "A good read with nothing failing clears nothing.")
        let raised = issues.fail(signal, "Timed out.", at: t0 + 10)
        #expect(!raised && issues.issue(for: signal)?.attempts == 1 && issues.issue(for: signal)?.since == t0 + 10)
    }

    /// Two signals count apart; the current issues are oldest first.
    @Test func signalsCountApartOldestFirst() {
        var issues = SignalReadIssues()
        issues.fail(other, "Refused.", at: t0 + 5)
        issues.fail(signal, "Timed out.", at: t0)
        issues.fail(signal, "Timed out.", at: t0 + 10)
        #expect(issues.current.map(\.signal) == [signal, other])
        #expect(issues.current.map(\.attempts) == [2, 1])
        issues.succeed(signal)
        #expect(issues.current.map(\.signal) == [other])
    }

    /// Pruning drops the issues of signals no longer read and returns them, so a raised banner can go with its signal.
    @Test func pruningDropsTheIssuesOfSignalsNoLongerRead() {
        var issues = SignalReadIssues()
        issues.fail(signal, "Timed out.", at: t0)
        issues.fail(other, "Refused.", at: t0 + 5)
        let gone = issues.prune(keeping: [signal])
        #expect(gone.map(\.signal) == [other])
        #expect(issues.current.map(\.signal) == [signal])
        #expect(issues.prune(keeping: [signal]).isEmpty)
    }

    /// The words: the source that fails, and the next try in 24-hour time, with its weekday only across midnight.
    @Test func theSentenceAndTheRetryTime() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Brussels")!
        let failed = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 14, minute: 0))!
        #expect(SignalReadIssues.sentence(name: "Reviews for me", source: "GitLab") == "“Reviews for me” can’t read GitLab.")
        #expect(SignalReadIssues.retry(at: failed + 300, from: failed, calendar: calendar) == "AiTerm tries again at 14:05.")
        let late = calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 23, minute: 58))!
        #expect(SignalReadIssues.retry(at: late + 300, from: late, calendar: calendar) == "AiTerm tries again at Thursday 00:03.")
    }
}
