import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalPollerTests {
    @Test func differentQueriesPublishOneCompletePassAndAnEditForcesACurrentFullRead() async {
        let reader = SignalPollReader(), work = OperatorWork(), clock = SignalPollClock()
        let poller = SignalPoller(work: work, now: { clock.date })
        let a = UUID(), b = UUID()
        var batches: [[UUID]] = []
        poller.onPass = { batches.append($0.flatMap(\.signals)) }
        let registrations: [SignalPoller.Registration] = [
            .init(id: a, sourceHost: "jira", readKey: "a", isJira: true, reader: reader),
            .init(id: b, sourceHost: "jira", readKey: "b", isJira: true, reader: reader)]
        poller.replace(registrations); poller.tick(); await work.settled()
        #expect(batches.count == 1 && Set(batches[0]) == Set([a, b]))
        poller.replace(registrations, refresh: [a]); poller.tick(); await work.settled()
        #expect(await reader.calls.map(\.full) == [true, true, true], "Save starts current matches even before the minute is up.")
        #expect(batches.count == 2 && batches.last == [a])
        poller.stop()
    }

    @Test func equalQueriesShareAReadAndJiraSweepsEveryTenMinutes() async {
        let clock = SignalPollClock(), reader = SignalPollReader(), work = OperatorWork()
        let poller = SignalPoller(work: work, now: { clock.date })
        let a = UUID(), b = UUID()
        var batches: [[UUID]] = []
        poller.onPass = { batches.append($0.flatMap(\.signals)) }
        poller.replace([.init(id: a, sourceHost: "jira", readKey: "query", isJira: true, reader: reader),
                        .init(id: b, sourceHost: "jira", readKey: "query", isJira: true, reader: reader)])
        poller.tick(); await work.settled()
        #expect(await reader.calls.count == 1 && batches.first?.count == 2)
        clock.date += 61
        poller.tick(); await work.settled()
        #expect(await reader.calls.map(\.full) == [true, false])
        clock.date += 540
        poller.tick(); await work.settled()
        #expect(await reader.calls.map(\.full) == [true, false, true])
        poller.stop()
    }

    @Test func incompleteReadsBackOffAndAdvanceNoCursor() async {
        let clock = SignalPollClock(), reader = SignalPollReader(), work = OperatorWork()
        await reader.setComplete(false)
        let poller = SignalPoller(work: work, now: { clock.date })
        var published = 0
        poller.onPass = { _ in published += 1 }
        poller.replace([.init(id: UUID(), sourceHost: "jira", readKey: "query", isJira: true, reader: reader)])
        poller.tick(); await work.settled()
        clock.date += 60
        poller.tick(); await work.settled()
        #expect(await reader.calls.count == 1 && published == 0)
        await reader.setComplete(true)
        clock.date += 241
        poller.tick(); await work.settled()
        #expect(await reader.calls.count == 2 && published == 1)
        #expect(await reader.calls.last?.since == nil)
        poller.stop()
    }

    /// The 19 Nov wake: a read that failed while the network was gone is read on the first tick after it returns, not five
    /// minutes later, and a read that succeeded keeps its cursor.
    @Test func theNetworkReturningMakesAFailedReadDueAndKeepsASucceededCursor() async {
        let clock = SignalPollClock(), failing = SignalPollReader(), fine = SignalPollReader(), work = OperatorWork()
        await failing.setFailing(true)
        let poller = SignalPoller(work: work, now: { clock.date })
        var failures = 0
        poller.onFailure = { _, _ in failures += 1 }
        poller.replace([.init(id: UUID(), sourceHost: "gitlab", readKey: "threads", isJira: false, reader: failing),
                        .init(id: UUID(), sourceHost: "jira", readKey: "query", isJira: true, reader: fine)])
        poller.tick(); await work.settled()
        #expect(await fine.calls.count == 1 && failures == 1)
        clock.date += 61
        poller.tick(); await work.settled()
        #expect(await failing.calls.count == 1, "A failed read waits out its back-off.")
        await failing.setFailing(false)
        clock.date += 5
        poller.networkReturned()
        poller.tick(); await work.settled()
        #expect(await failing.calls.count == 2 && failures == 1)
        #expect(await fine.calls.map(\.full) == [true, false, false], "The Jira read stays a changes-only read.")
        #expect(await fine.calls.last?.since != nil)
        poller.stop()
    }

    /// A read that was already waiting when the network came back, and times out afterwards, is not held for the back-off.
    @Test func aReadThatFailsAfterTheNetworkReturnedIsDueOnTheNextTick() async {
        let clock = SignalPollClock(), entered = TestLatch(), release = TestLatch(), work = OperatorWork()
        let reader = SignalTimingOutReader(entered: entered, release: release)
        let poller = SignalPoller(work: work, now: { clock.date })
        var failures = 0
        poller.onFailure = { _, _ in failures += 1 }
        poller.replace([.init(id: UUID(), sourceHost: "gitlab", readKey: "threads", isJira: false, reader: reader)])
        poller.tick(); await entered.wait()
        poller.networkReturned(); release.signal()
        await work.settled()
        #expect(failures == 1)
        clock.date += 61
        poller.tick(); await work.settled()
        #expect(await reader.calls == 2)
        poller.stop()
    }

    /// Each registration may read on its own rule: a read key is due only while a signal sharing it may read, and its
    /// observation, or its failure, names only those that still may once the read is back.
    @Test func aReadKeyIsReadForAndReportedToOnlyTheSignalsThatMayRead() async {
        let clock = SignalPollClock(), reader = SignalPollReader(), work = OperatorWork()
        let poller = SignalPoller(work: work, now: { clock.date })
        let project = UUID(), paused = UUID(), alone = UUID()
        var allowed: Set<UUID> = [project]
        poller.mayRead = { allowed.contains($0) }
        var batches: [[UUID]] = [], failures: [[UUID]] = []
        poller.onPass = { batches.append($0.flatMap(\.signals)) }
        poller.onFailure = { ids, _ in failures.append(ids) }
        poller.replace([.init(id: project, sourceHost: "jira", readKey: "shared", isJira: true, reader: reader),
                        .init(id: paused, sourceHost: "jira", readKey: "shared", isJira: true, reader: reader),
                        .init(id: alone, sourceHost: "jira", readKey: "other", isJira: true, reader: reader)])
        poller.tick(); await work.settled()
        #expect(await reader.calls.count == 1, "The key no signal may read is not due.")
        #expect(batches == [[project]])

        clock.date += 61
        await reader.setFailing(true)
        poller.tick(); await work.settled()
        #expect(failures == [[project]])

        // Allowed when the read starts, no longer when it is back: nothing is published and nothing is due early.
        let entered = TestLatch(), release = TestLatch()
        let held = SignalHeldReader(entered: entered, release: release)
        poller.replace([.init(id: project, sourceHost: "gitlab", readKey: "threads", isJira: false, reader: held)])
        poller.tick(); await entered.wait()
        allowed = []
        release.signal(); await work.settled()
        #expect(batches.count == 1 && failures.count == 1)
        poller.stop()
    }

    @Test func stopDropsALateReadAndOverlappingTicksStartNoDuplicate() async {
        let clock = SignalPollClock(), entered = TestLatch(), release = TestLatch(), work = OperatorWork()
        let reader = SignalHeldReader(entered: entered, release: release)
        let poller = SignalPoller(work: work, now: { clock.date })
        var published = 0
        poller.onPass = { _ in published += 1 }
        poller.replace([.init(id: UUID(), sourceHost: "host", readKey: "query", isJira: false, reader: reader)])
        poller.tick(); await entered.wait()
        poller.tick(); poller.stop(); release.signal()
        await work.settled()
        #expect(published == 0)
    }
}

@MainActor private final class SignalPollClock { var date = Date(timeIntervalSince1970: 1_800_000_000) }
private actor SignalPollReader: SignalSourceReader {
    struct Call: Sendable { var since: Date?; var full: Bool }
    var calls: [Call] = []
    var complete = true, failing = false
    func setComplete(_ value: Bool) { complete = value }
    func setFailing(_ value: Bool) { failing = value }
    func poll(since: Date?, full: Bool) async throws -> SignalRead {
        calls.append(Call(since: since, full: full))
        if failing { throw URLError(.notConnectedToInternet) }
        return SignalRead(items: [], complete: complete, full: full)
    }
}
/// Times out every read; the first one only once released.
private actor SignalTimingOutReader: SignalSourceReader {
    let entered: TestLatch, release: TestLatch
    var calls = 0
    init(entered: TestLatch, release: TestLatch) { self.entered = entered; self.release = release }
    func poll(since: Date?, full: Bool) async throws -> SignalRead {
        calls += 1
        if calls == 1 { entered.signal(); await release.wait() }
        throw URLError(.timedOut)
    }
}
private struct SignalHeldReader: SignalSourceReader {
    var entered: TestLatch, release: TestLatch
    func poll(since: Date?, full: Bool) async throws -> SignalRead {
        entered.signal(); await release.wait()
        return SignalRead(items: [], complete: true)
    }
}
