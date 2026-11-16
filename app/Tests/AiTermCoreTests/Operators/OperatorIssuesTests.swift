import Foundation
import Testing
@testable import AiTermCore

@Suite struct OperatorIssuesTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aRetriedSourceNeedsThreeFailuresInARowAndASuccessClearsIt() {
        var issues = OperatorIssues()
        #expect(issues.fail(.wake, "The helper timed out.", at: t0) == .started(.init(source: .wake, text: "The helper timed out.", since: t0, attempts: 1)))
        #expect(issues.attention == nil && issues.current.count == 1)
        #expect(issues.fail(.wake, "The helper timed out.", at: t0 + 5) == nil, "A repeated failure is not logged again.")
        #expect(issues.attention == nil)
        _ = issues.fail(.wake, "The helper timed out.", at: t0 + 10)
        #expect(issues.attention?.source == .wake && issues.attention?.attempts == 3 && issues.attention?.since == t0)
        guard case .recovered(let issue) = issues.succeed(.wake, at: t0 + 15) else { Issue.record("A success recovers."); return }
        #expect(issue.attempts == 3 && issues.current.isEmpty && issues.attention == nil)
        #expect(issues.succeed(.wake, at: t0 + 20) == nil, "A success with nothing failing reports nothing.")
    }
    @Test func aPersonStartedActionNeedsYouAtOnceUntilThatSameActionSucceeds() {
        var issues = OperatorIssues()
        _ = issues.fail(.openWindow, "The window is gone.", at: t0)
        #expect(issues.attention?.source == .openWindow)
        _ = issues.succeed(.wake, at: t0 + 1)
        #expect(issues.attention?.source == .openWindow, "An unrelated success cannot hide it.")
        _ = issues.succeed(.openWindow, at: t0 + 2)
        #expect(issues.attention == nil)
    }
    @Test func twoSourcesFailingAndOneRecoveringKeepsTheOther() {
        var issues = OperatorIssues()
        for at in 0..<3 { _ = issues.fail(.wake, "Wake failed.", at: t0 + Double(at)); _ = issues.fail(.reply, "Reply failed.", at: t0 + Double(at) + 0.5) }
        #expect(issues.attention?.source == .wake, "The oldest issue that needs the person is shown.")
        _ = issues.succeed(.wake, at: t0 + 9)
        #expect(issues.attention?.source == .reply && issues.current.map(\.source) == [.reply])
    }
    @Test func aChangedReasonIsReportedOnceAndKeepsTheStreak() {
        var issues = OperatorIssues()
        _ = issues.fail(.wake, "Timed out.", at: t0)
        #expect(issues.fail(.wake, "Refused: a wake line may not carry a digit.", at: t0 + 1)
                == .changed(.init(source: .wake, text: "Refused: a wake line may not carry a digit.", since: t0, attempts: 2)))
    }
    @Test func theIssueEncodesItsSourceTextAndWhetherItNeedsThePerson() throws {
        var issues = OperatorIssues()
        _ = issues.fail(.takeOver, "The guard could not be refreshed.", at: t0)
        let line = try #require(JSONValue(encoding: issues.current).arrayValue?.first)
        #expect(line["source"] == "takeOver" && line["text"] == "The guard could not be refreshed." && line["needsYou"] == true)
        #expect(OperatorIssues.Source.takeOver.label == "Take Over")
    }
}
