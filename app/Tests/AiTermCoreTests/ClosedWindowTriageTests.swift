import Foundation
import Testing
@testable import AiTermCore

/// When a task window iTerm2 reports closed is asked about (`ClosedWindowTriage`): a person's close,
/// alone, is; iTerm2 quitting, crashing or coming back after either is not.
@Suite struct ClosedWindowTriageTests {
    let start = ContinuousClock.now
    let task = UUID(), other = UUID()

    func at(_ milliseconds: Int) -> ContinuousClock.Instant { start.advanced(by: .milliseconds(milliseconds)) }

    func synced() -> ClosedWindowTriage {
        var triage = ClosedWindowTriage()
        triage.itermSynced(true, at: at(0))
        return triage
    }

    @Test func theHoldIsOneSecond() {
        #expect(ClosedWindowTriage.hold == .seconds(1))
    }

    @Test func aLoneCloseIsAskedAboutOnceItsHoldIsOver() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        #expect(triage.isHolding)
        #expect(triage.due(at: at(900)).isEmpty)
        #expect(triage.due(at: at(1000)) == [task])
        #expect(triage.due(at: at(2000)).isEmpty, "asked once")
        #expect(!triage.isHolding)
    }

    @Test func aNewTriageHoldsNothing() {
        var triage = ClosedWindowTriage()
        #expect(!triage.isHolding)
        #expect(triage.due(at: at(10000)).isEmpty)
    }

    @Test func aCloseIsNotDueTheInstantItArrives() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        #expect(triage.due(at: at(0)).isEmpty)
        #expect(triage.due(at: at(999)).isEmpty)
        #expect(triage.isHolding, "asking early leaves it held")
        #expect(triage.due(at: at(1000)) == [task])
    }

    /// A quit closes its windows, then its API socket.
    @Test func itermDisconnectingDuringTheHoldIsAQuit() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.itermSynced(false, at: at(100))
        #expect(triage.due(at: at(1000)).isEmpty)
        #expect(!triage.isHolding)
    }

    @Test func aDisconnectLessThanASecondAfterACloseCancelsIt() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.itermSynced(false, at: at(999))
        #expect(!triage.isHolding)
        #expect(triage.due(at: at(5000)).isEmpty)
    }

    @Test func aDisconnectExactlyASecondAfterACloseDoesNotCancelIt() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.itermSynced(false, at: at(1000))
        #expect(triage.isHolding)
        #expect(triage.due(at: at(1000)) == [task])
    }

    /// The caller may get to `due` late: what came after the hold was over does not take the question back.
    @Test func aDisconnectAfterTheHoldEndedButBeforeDueStillAsksAboutIt() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.itermSynced(false, at: at(1500))
        #expect(triage.due(at: at(2000)) == [task])
    }

    @Test func aDisconnectCancelsOnlyTheClosesStillInsideTheirHold() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.windowClosed(task: other, at: at(1500))
        triage.itermSynced(false, at: at(2000))
        #expect(triage.due(at: at(5000)) == [task])
    }

    @Test func aBurstAfterAHeldCloseHoldEndedButBeforeDueStillAsksAboutIt() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.windowClosed(task: nil, at: at(1200))     // alone: more than a second after the first
        triage.windowClosed(task: nil, at: at(1500))     // a burst of its own
        #expect(triage.due(at: at(2500)) == [task])
    }

    @Test func aBurstCancelsOnlyTheClosesStillInsideTheirHold() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.windowClosed(task: other, at: at(1200))   // held: a second after the first
        triage.windowClosed(task: nil, at: at(1500))     // within a second of it
        #expect(triage.due(at: at(5000)) == [task], "the first stays due, the second is cancelled")
    }

    @Test func aDisconnectAfterTheQuestionWasTakenChangesNothing() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        #expect(triage.due(at: at(1000)) == [task])
        triage.itermSynced(false, at: at(1000))
        #expect(!triage.isHolding)
        #expect(triage.due(at: at(2000)).isEmpty)
    }

    /// A quit closes every window in a burst: a terminal's, or one AiTerm does not know, counts too.
    @Test func anotherWindowClosingWithinTheHoldIsAQuit() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.windowClosed(task: nil, at: at(400))
        #expect(triage.due(at: at(5000)).isEmpty)
        var both = synced()
        both.windowClosed(task: task, at: at(0))
        both.windowClosed(task: other, at: at(200))
        #expect(both.due(at: at(5000)).isEmpty)
    }

    @Test func anotherWindowClosingJustUnderASecondAfterIsAQuit() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.windowClosed(task: nil, at: at(999))
        #expect(!triage.isHolding)
        #expect(triage.due(at: at(5000)).isEmpty)
    }

    @Test func anotherWindowClosingExactlyASecondAfterIsNot() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.windowClosed(task: nil, at: at(1000))
        #expect(triage.due(at: at(1000)) == [task], "exactly one hold apart is two person's closes")
    }

    @Test func aTaskCloseExactlyASecondAfterAnotherWindowIsAskedAbout() {
        var triage = synced()
        triage.windowClosed(task: nil, at: at(0))
        triage.windowClosed(task: task, at: at(1000))
        #expect(triage.isHolding)
        #expect(triage.due(at: at(2000)) == [task])
    }

    @Test func aTaskCloseExactlyASecondAfterAnotherTaskIsAskedAboutBoth() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.windowClosed(task: other, at: at(1000))
        #expect(triage.due(at: at(1000)) == [task])
        #expect(triage.due(at: at(2000)) == [other])
    }

    /// The order the two windows close in does not matter: the burst is what is dropped.
    @Test func aTaskCloseJustUnderASecondAfterAnotherWindowIsAQuit() {
        var triage = synced()
        triage.windowClosed(task: nil, at: at(0))
        triage.windowClosed(task: task, at: at(999))
        #expect(!triage.isHolding, "another window closed less than a second before it")
        #expect(triage.due(at: at(5000)).isEmpty)
    }

    @Test func twoTaskClosesWithinASecondAreQuietInEitherOrder() {
        for (first, second) in [(task, other), (other, task)] {
            var triage = synced()
            triage.windowClosed(task: first, at: at(0))
            triage.windowClosed(task: second, at: at(300))
            #expect(triage.due(at: at(5000)).isEmpty)
        }
    }

    @Test func aTerminalClosingBeforeATaskWithinASecondIsQuiet() {
        var triage = synced()
        triage.windowClosed(task: nil, at: at(0))
        triage.windowClosed(task: task, at: at(300))
        #expect(triage.due(at: at(5000)).isEmpty)
    }

    @Test func aChainOfClosesStaysQuiet() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.windowClosed(task: nil, at: at(600))
        triage.windowClosed(task: other, at: at(1200))
        #expect(triage.due(at: at(5000)).isEmpty, "each came within a second of the one before")
    }

    @Test func aChainEndingExactlyASecondAfterItsLastCloseAsksAboutTheNext() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.windowClosed(task: nil, at: at(600))
        triage.windowClosed(task: other, at: at(1600))
        #expect(triage.due(at: at(2600)) == [other])
    }

    @Test func closesASecondOrMoreApartAreEachAskedAbout() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        #expect(triage.due(at: at(1000)) == [task])
        triage.windowClosed(task: other, at: at(2500))
        #expect(triage.due(at: at(3500)) == [other])
    }

    @Test func aCloseExactlyASecondAfterOneThatWasTakenIsAskedAbout() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        #expect(triage.due(at: at(1000)) == [task])
        triage.windowClosed(task: other, at: at(1000))
        #expect(triage.due(at: at(2000)) == [other])
    }

    @Test func aCloseWithinASecondOfOneNotYetTakenIsQuiet() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        #expect(triage.due(at: at(950)).isEmpty)
        triage.windowClosed(task: other, at: at(950))
        #expect(!triage.isHolding)
        #expect(triage.due(at: at(5000)).isEmpty)
    }

    @Test func closesTwoSecondsApartAreBothAskedAboutInOneDueWhenTheCallerIsLate() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.windowClosed(task: other, at: at(1500))
        #expect(triage.due(at: at(5000)) == [task, other], "oldest first")
        #expect(!triage.isHolding)
    }

    @Test func aCloseWithNoTaskIsNeverAskedAbout() {
        var triage = synced()
        triage.windowClosed(task: nil, at: at(0))
        #expect(!triage.isHolding)
        #expect(triage.due(at: at(5000)).isEmpty)
    }

    /// A removal's or the checkout cleanup's own close is the caller's nil: it neither is held nor asked
    /// about, though it still counts as a window that closed.
    @Test func aCloseTheCallerOwnsStillCountsAsAWindowClosing() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.windowClosed(task: nil, at: at(500))
        #expect(triage.due(at: at(5000)).isEmpty)
    }

    /// Before the snapshot that follows a connection, a close may be one iTerm2 lost while it was away,
    /// which the daemon announces on its first tick back.
    @Test func aCloseBeforeTheSnapshotAfterAConnectionIsNeverAskedAbout() {
        var triage = ClosedWindowTriage()
        triage.windowClosed(task: task, at: at(0))
        #expect(!triage.isHolding, "no snapshot yet")
        triage.itermSynced(true, at: at(0))
        triage.itermSynced(false, at: at(0))   // iterm.connected: a new iTerm2, its snapshot not in yet
        triage.windowClosed(task: task, at: at(5000))
        #expect(!triage.isHolding)
        triage.itermSynced(true, at: at(5000))
        triage.windowClosed(task: other, at: at(10000))
        #expect(triage.due(at: at(11000)) == [other])
    }

    @Test func aCloseBeforeAnySnapshotLeavesNothingToAskAboutEvenLater() {
        var triage = ClosedWindowTriage()
        triage.windowClosed(task: task, at: at(0))
        #expect(triage.due(at: at(5000)).isEmpty)
        triage.itermSynced(true, at: at(5000))
        #expect(triage.due(at: at(6000)).isEmpty, "the snapshot does not bring it back")
    }

    @Test func aDisconnectedStateOnItsOwnHoldsNothing() {
        var triage = ClosedWindowTriage()
        triage.itermSynced(false, at: at(0))
        triage.windowClosed(task: task, at: at(0))
        #expect(!triage.isHolding)
        #expect(triage.due(at: at(5000)).isEmpty)
    }

    /// iterm.connected, then the windows iTerm2 lost while away, then the snapshot, then lone closes.
    @Test func aReconnectFollowedByLoneClosesAsksAboutEachLoneClose() {
        var triage = synced()
        triage.itermSynced(false, at: at(0))             // iterm.disconnected
        triage.itermSynced(false, at: at(0))             // iterm.connected, snapshot to come
        triage.windowClosed(task: task, at: at(0))       // announced on the first tick back
        triage.windowClosed(task: other, at: at(10))
        triage.itermSynced(true, at: at(10))             // the snapshot
        #expect(triage.due(at: at(5000)).isEmpty)
        triage.windowClosed(task: task, at: at(6000))    // the person closes one window
        #expect(triage.due(at: at(7000)) == [task])
        triage.windowClosed(task: other, at: at(9000))   // and, later, another
        #expect(triage.due(at: at(10000)) == [other])
    }

    /// The tick-back closes, the snapshot, and a person's close less than a second later are still a burst.
    @Test func aPersonsCloseRightAfterTheCatchUpClosesIsStillQuiet() {
        var triage = ClosedWindowTriage()
        triage.windowClosed(task: task, at: at(0))      // announced before the snapshot
        triage.itermSynced(true, at: at(0))
        triage.windowClosed(task: other, at: at(500))
        #expect(!triage.isHolding)
        #expect(triage.due(at: at(5000)).isEmpty)
    }

    @Test func aDisconnectThenALaterSnapshotAsksAboutALaterLoneClose() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.itermSynced(false, at: at(100))
        triage.itermSynced(true, at: at(200))
        #expect(triage.due(at: at(5000)).isEmpty, "the earlier close stays dropped")
        triage.windowClosed(task: other, at: at(6000))
        #expect(triage.due(at: at(7000)) == [other])
    }

    @Test func authFailedLeavesTheSyncedStateLikeADisconnect() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.itermSynced(false, at: at(100))   // iterm.auth_failed
        #expect(triage.due(at: at(2000)).isEmpty)
        triage.windowClosed(task: other, at: at(10000))
        #expect(!triage.isHolding)
    }

    @Test func syncingTwiceDropsNothing() {
        var triage = synced()
        triage.windowClosed(task: task, at: at(0))
        triage.itermSynced(true, at: at(500))    // a second connected snapshot, a periodic refresh
        #expect(triage.isHolding)
        #expect(triage.due(at: at(1000)) == [task])
    }

    @Test func triagesCompareEqualByTheirState() {
        var a = synced(), b = synced()
        #expect(a == b)
        a.windowClosed(task: task, at: at(0))
        #expect(a != b)
        b.windowClosed(task: task, at: at(0))
        #expect(a == b)
    }
}
