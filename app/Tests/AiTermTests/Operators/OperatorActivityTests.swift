import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore

@MainActor struct OperatorActivityTests {
    @Test func repeatedActionsAndTheirResultsEachHaveAnIdentity() async {
        let tracker = OperatorActivityTracker()
        var events: [OperatorActivity] = []
        tracker.changed = { events.append(tracker.event) }
        for _ in 0..<2 { await tracker.during("reading status") {} }
        #expect(events.compactMap(\.line).map(\.text) == ["reading status", "reading status"])
        #expect(Set(events.map(\.id)).count == 4)
        #expect(tracker.event.line == nil, "A result restores the current workload status.")
        #expect(tracker.event.completed?.text == "reading status", "A quick action remains available to the caption even when no frame saw its start.")
    }

    @Test func finishingANestedActionRestoresTheActionStillRunning() async {
        let tracker = OperatorActivityTracker()
        await tracker.during("answering PAY-1’s worker") {
            await tracker.during("consulting the Oracle") {
                #expect(tracker.event.line?.text == "consulting the Oracle")
            }
            #expect(tracker.event.line?.text == "answering PAY-1’s worker")
        }
        #expect(tracker.event.line == nil)
    }
}
