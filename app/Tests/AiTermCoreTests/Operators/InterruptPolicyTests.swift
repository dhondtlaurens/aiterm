import Testing
import Foundation
@testable import AiTermCore

/// Spec §4.1's "Notifies you" table, stop by stop.
@Suite struct InterruptPolicyTests {
    private func decide(_ event: InterruptPolicy.Event, _ autonomy: Autonomy, proceeds: Bool = true,
                        waited: TimeInterval = 0) -> InterruptPolicy.Decision {
        InterruptPolicy.decide(event, autonomy: autonomy, otherWorkCanProceed: proceeds, waited: waited)
    }

    @Test(arguments: Autonomy.allCases)
    func promptsBlockedRunsPlansAndDoneRunsNotifyAtEveryStop(_ autonomy: Autonomy) {
        for event in [InterruptPolicy.Event.permissionPrompt, .unknownPrompt, .planWaiting, .runBlocked, .runComplete] {
            #expect(decide(event, autonomy, proceeds: true) == .notifyNow, "\(event) at \(autonomy)")
        }
    }

    @Test func askFirstNotifiesEveryQuestionAtOnce() {
        #expect(decide(.question(holdsUpEverything: false), .askFirst) == .notifyNow)
    }

    @Test func routineNotifiesAtOnceOnlyWhenTheQuestionHoldsUpEverything() {
        #expect(decide(.question(holdsUpEverything: true), .routine) == .notifyNow)
        #expect(decide(.question(holdsUpEverything: false), .routine) == .hold)
    }

    @Test func routineSendsTheBundleWhenNoOtherWorkCanGoOnOrAfterThirtyMinutes() {
        #expect(decide(.question(holdsUpEverything: false), .routine, proceeds: false) == .notifyNow)
        #expect(decide(.question(holdsUpEverything: false), .routine, waited: 29 * 60) == .hold)
        #expect(decide(.question(holdsUpEverything: false), .routine, waited: 30 * 60) == .notifyNow)
    }

    @Test func trustedSendsTheBundleOnlyWhenNoOtherWorkCanGoOn() {
        #expect(decide(.question(holdsUpEverything: true), .trusted, waited: 3600) == .hold)
        #expect(decide(.question(holdsUpEverything: false), .trusted, proceeds: false) == .notifyNow)
    }

    @Test func handsOffHoldsQuestionsForTheBlockedOrCompleteRun() {
        #expect(decide(.question(holdsUpEverything: true), .handsOff, proceeds: false, waited: 3600) == .hold)
        #expect(decide(.runBlocked, .handsOff) == .notifyNow)
        #expect(decide(.runComplete, .handsOff) == .notifyNow)
    }
}
