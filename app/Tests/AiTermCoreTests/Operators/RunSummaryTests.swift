import Testing
import Foundation
@testable import AiTermCore

/// What the Summary tab has to say about a broadcast: nothing yet, being written, written, never coming,
/// or the broadcast ended before it finished.
@Suite struct RunSummaryTests {
    private typealias F = OperatorFixtures
    private let t = F.epoch.addingTimeInterval(600)

    private func run(_ state: OperatorRunState = .active, completed: Bool = false, summary: String? = nil,
                     givenUp: Bool = false) -> OperatorRun {
        var run = F.run(state: state)
        if completed { run.completedAt = F.epoch }
        if let summary { run.summary = summary; run.summaryAt = t }
        run.summaryGivenUp = givenUp
        return run
    }

    @Test func aRunningBroadcastHasNoSummaryYet() {
        #expect(RunSummary(run(.active)) == .notYet)
    }

    @Test func aCompletedBroadcastIsWritingUntilItHasOne() {
        let summary = RunSummary(run(.complete, completed: true))
        #expect(summary == .writing)
        #expect(!summary.isSettled)
    }

    @Test func aWrittenSummaryIsShown() {
        let summary = RunSummary(run(.complete, completed: true, summary: "All done."))
        #expect(summary == .written(text: "All done.", at: t))
        #expect(summary.isSettled)
    }

    @Test func givenUpIsNotComing() {
        let summary = RunSummary(run(.complete, completed: true, givenUp: true))
        #expect(summary == .notComing)
        #expect(summary.isSettled)
    }

    @Test func endedAfterCompletingWithoutOneIsNotComing() {
        #expect(RunSummary(run(.stopped, completed: true)) == .notComing)
    }

    @Test func endedEarlyIsItsOwn() {
        #expect(RunSummary(run(.stopped)) == .endedEarly)
        #expect(RunSummary(run(.stopped, summary: "Stopped halfway.")) == .written(text: "Stopped halfway.", at: t))
    }

    @Test func askedToStopCountsAsEnded() {
        var asked = run(.active)
        asked.intent = .stopped
        #expect(RunSummary(asked) == .endedEarly)
    }

    @Test func reopenClearsTheOldSummary() {
        var old = run(.complete, completed: true, summary: "All done.", givenUp: true)
        old.reopen()
        old.state = .active
        #expect(RunSummary(old) == .notYet)
        #expect(old.summary == nil && old.summaryAt == nil && old.completedAt == nil && !old.summaryGivenUp)
    }

    @Test func theSummaryWaitIsFiveMinutes() {
        #expect(OperatorTiming.summaryWait == 300)
    }
}
