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

    func makeWaker(coalesce: Duration = .zero, retryAfter: Duration = .seconds(60)) -> OperatorWaker {
        OperatorWaker(daemon: { [daemon] in daemon }, session: { [op] _ in op.tab }, awake: { [op] _ in op.awake }, coalesce: coalesce,
                      retryAfter: retryAfter)
    }

    /// The run as `run_status` would show it with `questions` open questions.
    func status(questions: Int) -> RunStatus {
        var run = self.run
        run.questions = (0..<questions).map { OperatorServiceFixtures.question("q\($0)") }
        return RunStatus.build(state: OperatorServiceFixtures.state(projects: [project], runs: [run]), run: run.id, revision: 1, live: [:])!
    }

    var lines: [String] { daemon.requests("session.deliver").compactMap { $0.params["text"] as? String } }

    @Test func aBurstOfChangesIsOneLineSayingHowMany() async throws {
        let waker = makeWaker(coalesce: .milliseconds(50))
        waker.acknowledged(status(questions: 0), of: run.id)
        waker.observe(status(questions: 1), of: run.id)
        waker.observe(status(questions: 2), of: run.id)
        try await daemon.received("session.deliver")
        await waker.lastSend?.value
        #expect(lines == ["[AiTerm] 2 updates — call run_status"])
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
        #expect(lines == ["[AiTerm] 1 update — call run_status"])
    }

    @Test func whatTheOperatorHasSeenWakesNothing() async throws {
        let waker = makeWaker()
        waker.acknowledged(status(questions: 0), of: run.id)
        waker.observe(status(questions: 1), of: run.id)
        waker.acknowledged(status(questions: 1), of: run.id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(lines.isEmpty)
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
        #expect(lines == ["[AiTerm] reconnected — call run_status"])
    }

    @Test func aRefusedWakeIsKeptAndTriedAgainLaterEvenIfTheTabNeverChanges() async throws {
        daemon.deliveries = [Delivery(result: .refused, reason: "you are typing"), Delivery(result: .delivered, reason: nil)]
        let waker = makeWaker(retryAfter: .milliseconds(50))
        waker.acknowledged(status(questions: 0), of: run.id)
        waker.observe(status(questions: 1), of: run.id)
        try await daemon.received("session.deliver", count: 2)
        await waker.lastSend?.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(lines == ["[AiTerm] 1 update — call run_status", "[AiTerm] 1 update — call run_status"])
    }

    @Test func aWakeStaysRefusedWithoutSpinning() async throws {
        daemon.deliveries = [Delivery(result: .refused, reason: "unsent text waits in its input")]
        let waker = makeWaker(retryAfter: .milliseconds(100))
        waker.acknowledged(status(questions: 0), of: run.id)
        waker.observe(status(questions: 1), of: run.id)
        try await Task.sleep(for: .milliseconds(350))
        #expect(lines.count >= 2 && lines.count <= 5)
        waker.acknowledged(status(questions: 1), of: run.id)
        let after = lines.count
        try await Task.sleep(for: .milliseconds(250))
        #expect(lines.count == after)
    }
}
