import Foundation
import Testing
@testable import AiTermTestSupport

/// `eventually` charges its timeout for time the condition had, not for time its caller waited
/// for a turn.
@MainActor struct EventuallyTests {
    /// The main actor is held past the whole timeout while the wait is between checks, and what it
    /// waits for comes due in that time. Once the actor is free, the next check sees it: the turn
    /// the wait was kept from is not charged to the condition.
    @Test func aCallerKeptFromItsTurnIsNotChargedForIt() async {
        var done = false
        /// What another main-actor test's synchronous body does to this one.
        func holdTheActor() { Thread.sleep(forTimeInterval: 0.5) }
        Task { try? await Task.sleep(for: .milliseconds(20)); done = true }
        Task { try? await Task.sleep(for: .milliseconds(1)); holdTheActor() }
        #expect(await eventually(timeout: 0.2) { done })
    }

    /// A condition that never holds still times out, with an issue at the caller.
    @Test func aConditionThatNeverHoldsTimesOut() async {
        await withKnownIssue {
            #expect(await eventually(timeout: 0.1) { false } == false)
        }
    }
}
