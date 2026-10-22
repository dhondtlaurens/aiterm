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

    /// What a host says of a task's request is filled in by `run_status` alone: the run reads without it, and the difference is no news.
    @Test func whatTheHostSaysOfARequestIsNoNews() async throws {
        let hand = HandSleeper(), waker = makeWaker(by: hand)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "A", state: .inReview)
        var read = RunStatus.build(state: OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), run: run.id, revision: 1, live: [:])!
        let plain = read
        read.tasks[0].mergeRequest = MergeRequestState(iid: 12, url: FakeMergeHost.url, draft: true, pipeline: "failed", mergeable: "ci_must_pass",
                                                       approvedBy: [], head: nil)
        waker.acknowledged(read, of: run.id)
        waker.observe(plain, of: run.id)
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

    // -- a worker's turn (spec §J) ------------------------------------------------------------------

    /// The run with `tasks`, whose first workers ended their turn as `facts` say, by key.
    func status(_ tasks: [TaskItem], turns facts: [String: TaskLiveFacts]) -> RunStatus {
        let live = Dictionary(uniqueKeysWithValues: tasks.compactMap { task in facts[task.operated!.key].map { (task.id, $0) } })
        return RunStatus.build(state: OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: tasks), run: run.id,
                               revision: 1, live: live)!
    }

    /// A worker that ends its turn asking something wakes the Operator with a line that says what kind of news it is; the
    /// line carries no key, since a key's digits are what a menu opening as it lands could take for its answer, and
    /// run_status's `workerAsks` names the task. Each of the three kinds has its line; two pieces of news at once are the
    /// generic line.
    @Test func aWorkerQuestionWakesTheOperatorNamingTheKind() async throws {
        let asks = TaskLiveFacts(status: .idle, lastMessage: "Should I also bump eslint?", commitsAhead: 1)
        let empty = TaskLiveFacts(status: .idle, lastMessage: "Nothing to update.", commitsAhead: 0)
        let quiet = TaskLiveFacts(status: .working)
        let tasks = ["PAY-2", "PAY-3"].map { OperatorServiceFixtures.task(in: run, project: project, key: $0, state: .working) }
        func woken(by news: [String: TaskLiveFacts]) async throws -> [String] {
            let daemon = RecordingDaemon(), hand = HandSleeper()
            let waker = OperatorWaker(daemon: { daemon }, session: { [op] _ in op.tab }, awake: { _ in true }, coalesce: .zero,
                                      sleep: { await hand.sleep($0) })
            waker.acknowledged(status(tasks, turns: ["PAY-2": quiet, "PAY-3": quiet]), of: run.id)
            waker.observe(status(tasks, turns: news), of: run.id)
            await hand.release(1)
            try await daemon.received("session.deliver")
            await waker.lastSend?.value
            return daemon.requests("session.deliver").compactMap { $0.params["text"] as? String }
        }
        #expect(try await woken(by: ["PAY-2": asks, "PAY-3": quiet]) == ["[AiTerm] one worker asks something, call run_status"])
        #expect(try await woken(by: ["PAY-2": empty, "PAY-3": quiet]) == ["[AiTerm] one task finished with no commit, call run_status"])
        #expect(try await woken(by: ["PAY-2": asks, "PAY-3": empty]) == ["[AiTerm] updates waiting, call run_status"])
    }

    /// Work done in an accepted task's worker after its acceptance wakes the Operator with its own line.
    @Test func workAfterAcceptanceWakesTheOperatorSayingSo() async throws {
        let hand = HandSleeper(), waker = makeWaker(by: hand)
        var accepted = OperatorServiceFixtures.task(in: run, project: project, key: "PAY-2", state: .accepted)
        accepted.operated?.acceptance = TaskAcceptance(resultSHA: "4f2a91c", prerequisiteSHAs: [], checkOutput: "ok", note: nil,
                                                       at: Date(timeIntervalSince1970: 0))
        func status(changed: Bool) -> RunStatus {
            RunStatus.build(state: OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [accepted]), run: run.id,
                            revision: 1, live: [accepted.id: TaskLiveFacts(status: .idle, changedAfterAcceptance: changed)])!
        }
        waker.acknowledged(status(changed: false), of: run.id)
        waker.observe(status(changed: true), of: run.id)
        await hand.release(1)
        try await daemon.received("session.deliver")
        #expect(lines == ["[AiTerm] one task changed after acceptance, call run_status"])
    }

    /// A prompt you typed into a task's worker, which the controller writes on its open question (`answeredInWindow`), wakes
    /// the Operator with a line that says what kind of news it is and names no question: a key's digits are what a menu
    /// opening as it lands could take for its answer, and run_status names the question. The question stays open.
    @Test func theOperatorIsWokenNamingTheTask() async throws {
        let hand = HandSleeper(), waker = makeWaker(by: hand)
        let task = OperatorServiceFixtures.task(in: run, project: project, key: "PAY-2", state: .working)
        func status(typed: String?) -> RunStatus {
            var run = self.run
            run.questions = [OperatorQuestion(id: "locale-2", text: "Which locale?", task: task.id, askedAt: Date(timeIntervalSince1970: 0),
                                              answeredInWindow: typed)]
            return RunStatus.build(state: OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), run: run.id,
                                   revision: 1, live: [task.id: TaskLiveFacts(status: .idle)])!
        }
        waker.acknowledged(status(typed: nil), of: run.id)
        waker.observe(status(typed: "Use nl-BE"), of: run.id)
        await hand.release(1)
        try await daemon.received("session.deliver")
        #expect(lines == ["[AiTerm] you may have answered one question in its worker's window, call run_status"])
    }

    /// A review with nothing waiting wakes the Operator with a keyless line, once per task per review: the same review going
    /// loud and quiet again, or the status read again, never repeats it; a new review of the task does (spec §K).
    @Test func itWakesOncePerReview() async throws {
        let waker = makeWaker(), quietLine = "[AiTerm] one task is in review with nothing waiting, call run_status"
        var task = OperatorServiceFixtures.task(in: run, project: project, key: "PAY-2", state: .inReview)
        func status(began: Double, threads: [String: Bool] = [:], minutes: Double) -> RunStatus {
            task.operated?.peopleReview = PeopleReview(threads: threads, startedAt: Date(timeIntervalSince1970: began))
            return RunStatus.build(state: OperatorServiceFixtures.state(projects: [project], runs: [run], tasks: [task]), run: run.id,
                                   revision: 1, live: [:], now: Date(timeIntervalSince1970: began + minutes * 60))!
        }
        func settle() async { await waker.lastCoalesce?.value; await waker.lastSend?.value }
        waker.acknowledged(status(began: 0, minutes: 4), of: run.id)
        waker.observe(status(began: 0, minutes: 5), of: run.id)
        await settle()
        #expect(lines == [quietLine])
        waker.observe(status(began: 0, minutes: 5), of: run.id)
        waker.observe(status(began: 0, minutes: 6), of: run.id)
        await settle()
        #expect(lines == [quietLine], "the same status again is no news")
        // The Operator looked; a reviewer opens a thread and resolves it, and the same review is quiet again.
        waker.acknowledged(status(began: 0, minutes: 7), of: run.id)
        waker.observe(status(began: 0, threads: ["t1": false], minutes: 8), of: run.id)
        waker.observe(status(began: 0, threads: ["t1": true], minutes: 9), of: run.id)
        await settle()
        #expect(lines.filter { $0 == quietLine }.count == 1, "no second line for the same review: \(lines)")
        // A new review of the task has its own start.
        waker.acknowledged(status(began: 1000, minutes: 1), of: run.id)
        waker.observe(status(began: 1000, minutes: 5), of: run.id)
        await settle()
        #expect(lines.filter { $0 == quietLine }.count == 2)
    }

    /// The turn lines are plain: no digit, no one-letter word (`isPlain`, the daemon's `wake_text_problem`).
    @Test func theTurnLinesArePlain() {
        for reason in OperatorWaker.turnReasons {
            #expect(OperatorWaker.isPlain(reason), "\(reason)")
            #expect(OperatorWaker.line(updates: 1, reason: .init(text: reason, colon: false)) == "[AiTerm] \(reason), call run_status")
        }
        #expect(OperatorWaker.turnReasons == ["one worker asks something", "one task changed after acceptance",
                                              "one task finished with no commit",
                                              "you may have answered one question in its worker's window"])
        #expect(OperatorWaker.isPlain(OperatorWaker.reviewQuietReason))
        #expect(OperatorWaker.reviewQuietReason == "one task is in review with nothing waiting")
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
