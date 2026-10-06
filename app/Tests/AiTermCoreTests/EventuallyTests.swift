import Foundation
import Testing
@testable import AiTermTestSupport

/// `eventually` charges its timeout for time the condition had, not for time its caller waited
/// for a turn.
///
/// Serialized: each test holds the main actor on purpose, and the hold of one is a late turn of
/// the other, which the wall-clock ceiling counts.
@MainActor @Suite(.serialized) struct EventuallyTests {
    /// The main actor is held past the whole timeout (but short of the wall-clock ceiling) while
    /// the wait is between checks, and what it waits for comes due in that time. Once the actor is
    /// free, the next check sees it: the turn the wait was kept from is not charged to the condition.
    @Test func aCallerKeptFromItsTurnIsNotChargedForIt() async {
        var done = false
        /// What another main-actor test's synchronous body does to this one.
        func holdTheActor() { Thread.sleep(forTimeInterval: 0.8) }
        Task { try? await Task.sleep(for: .milliseconds(20)); done = true }
        Task { try? await Task.sleep(for: .milliseconds(1)); holdTheActor() }
        #expect(await eventually(timeout: 0.5) { done })
    }

    /// What came due while the caller was kept from its turn is queued right behind the check that
    /// turn brings, so a wait whose time ran out during it gives that one more turn before calling
    /// the wait off: the actor is held past the wall-clock ceiling, and what the wait is for comes
    /// due in that time. This is how a busy parallel run timed out a wait whose condition held
    /// one turn later.
    @Test func aWaitThatRanOutWhileKeptFromItsTurnSeesWhatCameDueMeanwhile() async {
        let timeout = 0.2, hold = timeout * Double(wallClockFactor) + 0.1
        var done = false
        func holdTheActor() { Thread.sleep(forTimeInterval: hold) }
        Task { try? await Task.sleep(for: .milliseconds(20)); done = true }
        Task { try? await Task.sleep(for: .milliseconds(1)); holdTheActor() }
        #expect(await eventually(timeout: timeout) { done })
    }

    /// A wait kept from its turns past `wallClockFactor` times its timeout ends there, though it
    /// was charged less than the timeout: the actor is held once, for longer than that, so the
    /// check after it has been charged a single late turn.
    @Test func aWaitStopsAtTheWallClockCeilingWhateverItWasCharged() async {
        let timeout = 0.2, hold = timeout * Double(wallClockFactor) + 0.1
        func holdTheActor() { Thread.sleep(forTimeInterval: hold) }
        Task { holdTheActor() } // Runs once the wait first suspends.
        await withKnownIssue {
            #expect(await eventually(timeout: timeout) { false } == false)
        } matching: { issue in
            issue.description.contains("(wall clock: ")
        }
    }

    /// A condition that never holds still times out, with an issue at the caller.
    @Test func aConditionThatNeverHoldsTimesOut() async {
        await withKnownIssue {
            #expect(await eventually(timeout: 0.1) { false } == false)
        }
    }
}
