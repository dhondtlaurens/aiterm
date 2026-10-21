import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Waking the operator (spec §7.3): a short fixed line, coalesced, only while it is idle and its
/// operation is one that may be woken.
@MainActor @Suite struct OperatorWakerTests {
    /// The operator's tab and whether its run may be woken, as a test sets them.
    final class Operator { var tab: SessionInfo?; var awake = true }

    let daemon = RecordingDaemon(), op = Operator(), project = OperatorServiceFixtures.project()
    let run: OperatorRun
    init() {
        run = OperatorServiceFixtures.run(projects: [project], state: .active)
        op.tab = OperatorServiceFixtures.session("op", tag: run.id)
    }

    /// A sleep a test ends by hand: each wait the waker starts is counted and held until `releaseAll`.
    @MainActor final class HandSleeper {
        private(set) var requested = 0
        private var held: [CheckedContinuation<Void, Never>] = []
        func sleep(_ duration: Duration) async { requested += 1; await withCheckedContinuation { held.append($0) } }
        /// Waits until the waker has started its `n`th wait, which it does a moment after the call that armed it.
        func started(_ n: Int) async { await eventually(describing: "wait \(n) to start") { requested == n && !held.isEmpty } }
        /// Ends the `n`th wait, once it has started.
        func release(_ n: Int) async { await started(n); releaseAll() }
        func releaseAll() { let waiting = held; held = []; for continuation in waiting { continuation.resume() } }
    }

    func makeWaker(coalesce: Duration = .zero, retryAfter: Duration = .seconds(60), by hand: HandSleeper? = nil) -> OperatorWaker {
        guard let hand else {
            return OperatorWaker(daemon: { [daemon] in daemon }, session: { [op] _ in op.tab }, awake: { [op] _ in op.awake },
                                 coalesce: coalesce, retryAfter: retryAfter)
        }
        return OperatorWaker(daemon: { [daemon] in daemon }, session: { [op] _ in op.tab }, awake: { [op] _ in op.awake },
                             coalesce: coalesce, retryAfter: retryAfter, sleep: { await hand.sleep($0) })
    }

    /// The run as `run_status` would show it with `questions` open questions.
    func status(questions: Int) -> RunStatus {
        var run = self.run
        run.questions = (0..<questions).map { OperatorServiceFixtures.question("q\($0)") }
        return RunStatus.build(state: OperatorServiceFixtures.state(projects: [project], runs: [run]), run: run.id, revision: 1, live: [:])!
    }

    var lines: [String] { daemon.requests("session.deliver").compactMap { $0.params["text"] as? String } }

    /// Usage readings drift with every report from the vendor: the operator reads them when it asks.
    @Test func aChangeOfUsageAloneIsNoNews() async throws {
        let hand = HandSleeper(), waker = makeWaker(by: hand)
        func withUsage(_ percent: Int) -> RunStatus {
            let state = OperatorServiceFixtures.state(projects: [project], runs: [run])
            return RunStatus.build(state: state, run: run.id, revision: 1, live: [:],
                                   runLive: RunLiveFacts(weeklyUsage: [.claude: percent]))!
        }
        waker.acknowledged(withUsage(40), of: run.id)
        waker.observe(withUsage(41), of: run.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(hand.requested == 0 && lines.isEmpty)
    }

    @Test func aBurstOfChangesIsOneLineSayingHowMany() async throws {
        let hand = HandSleeper(), waker = makeWaker(by: hand)
        waker.acknowledged(status(questions: 0), of: run.id)
        waker.observe(status(questions: 1), of: run.id)
        waker.observe(status(questions: 2), of: run.id)
        await hand.release(1)
        try await daemon.received("session.deliver")
        await waker.lastSend?.value
        #expect(lines == ["[AiTerm] updates waiting, call run_status"])
        let sent = try #require(daemon.requests("session.deliver").first)
        #expect(sent.params["sessionId"] as? String == "op")
        #expect(sent.params["wake"] as? Bool == true)
    }

    @Test func theFirstLookAtARunIsWhatItHasSeen() async throws {
        let waker = makeWaker()
        waker.observe(status(questions: 1), of: run.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(lines.isEmpty)
    }

    @Test func aWorkingOperatorIsWokenOnlyOnceItsTabIsIdle() async throws {
        let waker = makeWaker()
        waker.acknowledged(status(questions: 0), of: run.id)
        op.tab?.state = .working
        waker.observe(status(questions: 1), of: run.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(lines.isEmpty)
        op.tab?.state = .idle
        waker.operatorSessionChanged(run.id)
        try await daemon.received("session.deliver")
        #expect(lines == ["[AiTerm] updates waiting, call run_status"])
    }

    @Test func whatTheOperatorHasSeenWakesNothing() async throws {
        let waker = makeWaker()
        waker.acknowledged(status(questions: 0), of: run.id)
        waker.observe(status(questions: 1), of: run.id)
        waker.acknowledged(status(questions: 1), of: run.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(lines.isEmpty)
    }

    @Test func theOperatorsOwnChangeIsSeenWhenItHadSeenEverythingBefore() async throws {
        let hand = HandSleeper(), waker = makeWaker(by: hand)
        waker.acknowledged(status(questions: 0), of: run.id)
        waker.ownChange(from: status(questions: 0), to: status(questions: 1), of: run.id)
        // What its own call made is looked at next: it is the news the operator already has.
        waker.observe(status(questions: 1), of: run.id)
        #expect(hand.requested == 0)
        #expect(lines.isEmpty)
        // A change after that is news again.
        waker.observe(status(questions: 2), of: run.id)
        await hand.release(1)
        try await daemon.received("session.deliver")
        #expect(lines == ["[AiTerm] updates waiting, call run_status"])
    }

    @Test func anOwnChangeAfterNewsTheOperatorHasNotSeenStillWakesIt() async throws {
        let hand = HandSleeper(), waker = makeWaker(by: hand)
        waker.acknowledged(status(questions: 0), of: run.id)
        // News arrives, then the operator's call changes the run on top of it without having seen it.
        waker.observe(status(questions: 1), of: run.id)
        await hand.started(1)
        waker.ownChange(from: status(questions: 1), to: status(questions: 2), of: run.id)
        waker.observe(status(questions: 2), of: run.id)
        await hand.release(1)
        try await daemon.received("session.deliver")
        await waker.lastSend?.value
        #expect(lines == ["[AiTerm] updates waiting, call run_status"])
    }

    @Test func anOperationThatMayNotBeWokenIsNot() async throws {
        let waker = makeWaker()
        op.awake = false
        waker.acknowledged(status(questions: 0), of: run.id)
        waker.observe(status(questions: 1), of: run.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(lines.isEmpty)
    }

    @Test func aRefusedWakeWaitsForTheNextIdleMomentAndIsNotRepeatedOnceItLands() async throws {
        daemon.deliveries = [Delivery(result: .refused, reason: "you are typing"), Delivery(result: .delivered, reason: nil)]
        let waker = makeWaker()
        waker.acknowledged(status(questions: 0), of: run.id)
        waker.observe(status(questions: 1), of: run.id)
        try await daemon.received("session.deliver")
        await waker.lastSend?.value
        waker.operatorSessionChanged(run.id)
        try await daemon.received("session.deliver", count: 2)
        await waker.lastSend?.value
        waker.operatorSessionChanged(run.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(lines.count == 2)
    }

    @Test func aReasonIsTheLineWhenItIsTheOnlyNews() async throws {
        let waker = makeWaker()
        waker.say("reconnected", to: run.id)
        try await daemon.received("session.deliver")
        #expect(lines == ["[AiTerm] reconnected, call run_status"])
    }

    @Test func aRefusedWakeIsKeptAndTriedAgainLaterEvenIfTheTabNeverChanges() async throws {
        daemon.deliveries = [Delivery(result: .refused, reason: "you are typing"), Delivery(result: .delivered, reason: nil)]
        let hand = HandSleeper(), waker = makeWaker(by: hand)
        waker.acknowledged(status(questions: 0), of: run.id)
        waker.observe(status(questions: 1), of: run.id)
        await hand.release(1)
        try await daemon.received("session.deliver")
        await hand.release(2)
        try await daemon.received("session.deliver", count: 2)
        await waker.lastSend?.value
        #expect(lines == ["[AiTerm] updates waiting, call run_status", "[AiTerm] updates waiting, call run_status"])
        // It landed: no third wait is started.
        try await Task.sleep(for: .milliseconds(50))
        #expect(hand.requested == 2)
    }

    @Test func aWakeStaysRefusedWithoutSpinning() async throws {
        daemon.deliveries = [Delivery(result: .refused, reason: "unsent text waits in its input")]
        let hand = HandSleeper(), waker = makeWaker(by: hand)
        waker.acknowledged(status(questions: 0), of: run.id)
        waker.observe(status(questions: 1), of: run.id)
        await hand.release(1)
        try await daemon.received("session.deliver")
        // One retry wait is started and nothing more is sent until it is over, however long that takes.
        await hand.started(2)
        #expect(lines.count == 1)
        await hand.release(2)
        try await daemon.received("session.deliver", count: 2)
        await hand.started(3)
        #expect(lines.count == 2)
        waker.acknowledged(status(questions: 1), of: run.id)
        hand.releaseAll()
        try await Task.sleep(for: .milliseconds(50))
        #expect(lines.count == 2 && hand.requested == 3)
    }
    @Test(arguments: [false, true])
    func newsCoalescedDuringDeliveryStillWakesAfterItCompletes(_ acknowledge: Bool) async throws {
        let held = RecordingDaemon(holding: "session.deliver"), hand = HandSleeper()
        let waker = OperatorWaker(daemon: { held }, session: { [op] _ in op.tab }, awake: { _ in true },
                                  coalesce: .zero, sleep: { await hand.sleep($0) })
        waker.acknowledged(status(questions: 0), of: run.id)
        waker.observe(status(questions: 1), of: run.id)
        await hand.release(1)
        try await held.received("session.deliver")
        let first = waker.lastSend
        if acknowledge { waker.acknowledged(status(questions: 1), of: run.id) }
        waker.observe(status(questions: 2), of: run.id)
        await hand.release(2)
        await waker.lastCoalesce?.value
        held.release()
        await first?.value
        // No session change is needed: the coalescing deadline has already passed.
        await eventually { held.requests("session.deliver").count == 2 }
        await waker.lastSend?.value
        #expect(held.requests("session.deliver").compactMap { $0.params["text"] as? String } == [
            "[AiTerm] updates waiting, call run_status", "[AiTerm] updates waiting, call run_status"
        ])
        waker.operatorSessionChanged(run.id)
        #expect(held.requests("session.deliver").count == 2)
    }

    @Test func aReasonArrivingDuringDeliveryGetsItsOwnWake() async throws {
        let held = RecordingDaemon(holding: "session.deliver"), hand = HandSleeper()
        let waker = OperatorWaker(daemon: { held }, session: { [op] _ in op.tab }, awake: { _ in true },
                                  coalesce: .zero, sleep: { await hand.sleep($0) })
        waker.say("reconnected", to: run.id)
        await hand.release(1)
        try await held.received("session.deliver")
        let first = waker.lastSend
        waker.say("operation complete", to: run.id)
        await hand.release(2)
        await waker.lastCoalesce?.value
        held.release()
        await first?.value
        await eventually { held.requests("session.deliver").count == 2 }
        await waker.lastSend?.value
        #expect(held.requests("session.deliver").compactMap { $0.params["text"] as? String } == [
            "[AiTerm] reconnected, call run_status", "[AiTerm] operation complete, call run_status"
        ])
    }

    @Test func forgettingDuringDeliveryPreservesReplacementNewsWithoutOverlappingWakes() async throws {
        let held = RecordingDaemon(holding: "session.deliver"), hand = HandSleeper()
        let waker = OperatorWaker(daemon: { held }, session: { [op] _ in op.tab }, awake: { _ in true },
                                  coalesce: .zero, sleep: { await hand.sleep($0) })
        waker.say("operation complete", to: run.id)
        await hand.release(1)
        try await held.received("session.deliver")
        let original = waker.lastSend

        waker.forget(run.id)
        waker.say("reconnected", to: run.id)
        await hand.release(2)
        await waker.lastCoalesce?.value
        waker.operatorSessionChanged(run.id)
        await Task.yield()
        #expect(held.requests("session.deliver").count == 1, "the forgotten delivery still owns the tab until it replies")

        held.release()
        await original?.value
        try await held.received("session.deliver", count: 2)
        await waker.lastSend?.value
        #expect(held.requests("session.deliver").compactMap { $0.params["text"] as? String } == [
            "[AiTerm] operation complete, call run_status", "[AiTerm] reconnected, call run_status"
        ])
        waker.operatorSessionChanged(run.id)
        await waker.lastSend?.value
        #expect(held.requests("session.deliver").count == 2)
    }

    // -- what a wake line may carry ----------------------------------------------------------------

    /// Every reason the app says, the ones that name a task by its key among them, and a few no prompt may read.
    nonisolated static let reasons = [
        "reconnected", "resumed", "broadcast complete", "operation complete", "the person took over PAY-2", "PAY-2 is handed back",
        "PAY-2 committed off its task branch", "PAY-2 is uncertain: its window has only a shell; no worker is confirmed",
        "PAY-2 merged", "PAY-2 can’t merge: the host gave no reason", "QUIET-1, LOUD-7 may be stalled", "review feedback on A",
        "Claude reviewed A", "Codex’s review of PAY-2 failed", "PAY-3 needs a rebase: PAY-2 was accepted again",
        "PAY-2: the merge watch stopped, the branch moved; call finish_task again when it can go on", "y", "a task", "1",
    ]

    /// No line carries a digit or a one-letter word a prompt opening as it lands could take for its answer.
    @Test(arguments: reasons) func noLineCarriesADigitOrAOneLetterWord(_ reason: String) {
        for count in 0...12 {
            for line in [OperatorWaker.line(updates: count, reason: nil),
                         OperatorWaker.line(updates: count, reason: .init(text: reason, colon: false)),
                         OperatorWaker.line(updates: count, reason: .init(text: reason, colon: true))] {
                let digits = line.filter(\.isNumber)
                #expect(digits.isEmpty, "\(line)")
                #expect(OperatorWaker.isPlain(line), "\(line)")
            }
        }
    }

    @Test func aPlainReasonIsTheLineAndAKeyedOneSaysUpdatesWait() {
        #expect(OperatorWaker.line(updates: 1, reason: .init(text: "reconnected", colon: false)) == "[AiTerm] reconnected, call run_status")
        #expect(OperatorWaker.line(updates: 1, reason: .init(text: "Codex’s review failed", colon: true))
                == "[AiTerm] Codex’s review failed: call run_status")
        #expect(OperatorWaker.line(updates: 1, reason: .init(text: "PAY-2 merged", colon: false)) == "[AiTerm] updates waiting, call run_status")
        #expect(OperatorWaker.line(updates: 3, reason: nil) == "[AiTerm] updates waiting, call run_status")
    }

    // -- a refused wake line, for the sidebar's Notice -----------------------------------------------

    /// What the waker reported: each refusal, and each time the Notice may come down.
    @MainActor final class Reports { var refused: [Delivery] = []; var cleared = 0 }

    func reporting(_ waker: OperatorWaker) -> Reports {
        let reports = Reports()
        waker.refused = { _, delivery in reports.refused.append(delivery) }
        waker.cleared = { _ in reports.cleared += 1 }
        return reports
    }

    @Test func aRefusalIsReportedAndADeliveredLineClearsIt() async throws {
        let unread = Delivery(result: .refused, reason: "unrecognised screen", code: .unrecognisedScreen)
        daemon.deliveries = [unread, Delivery(result: .delivered, reason: nil)]
        let waker = makeWaker()
        waker.acknowledged(status(questions: 0), of: run.id)
        let reports = reporting(waker)
        waker.observe(status(questions: 1), of: run.id)
        try await daemon.received("session.deliver")
        await waker.lastSend?.value
        #expect(reports.refused == [unread] && reports.cleared == 0)
        waker.operatorSessionChanged(run.id)
        try await daemon.received("session.deliver", count: 2)
        await waker.lastSend?.value
        #expect(reports.refused.count == 1 && reports.cleared == 1)
    }

    @Test func aPromptWaitingOnThePersonIsNotReported() async throws {
        daemon.deliveries = [Delivery(result: .refused, reason: "a permission prompt is open", code: .prompt)]
        let waker = makeWaker()
        waker.acknowledged(status(questions: 0), of: run.id)
        let reports = reporting(waker)
        waker.observe(status(questions: 1), of: run.id)
        try await daemon.received("session.deliver")
        await waker.lastSend?.value
        #expect(reports.refused.isEmpty)
    }

    @Test func aLineLeftUnsentClearsNothing() async throws {
        daemon.deliveries = [Delivery(result: .partial, reason: "before Enter, a permission prompt is open", code: .prompt)]
        let waker = makeWaker()
        waker.acknowledged(status(questions: 0), of: run.id)
        let reports = reporting(waker)
        waker.observe(status(questions: 1), of: run.id)
        try await daemon.received("session.deliver")
        await waker.lastSend?.value
        #expect(reports.refused.isEmpty && reports.cleared == 0)
    }

    @Test func runStatusAndForgettingTheRunClearIt() {
        let waker = makeWaker(), reports = reporting(waker)
        waker.acknowledged(status(questions: 0), of: run.id)
        #expect(reports.cleared == 1)
        waker.forget(run.id)
        #expect(reports.cleared == 2)
    }
}
