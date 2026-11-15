import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalPollerTests {
    @Test func differentQueriesPublishOneCompletePassAndAnEditForcesACurrentFullRead() async {
        let reader = SignalPollReader(), work = OperatorWork(), clock = SignalPollClock()
        let poller = SignalPoller(work: work, automatic: false, now: { clock.date })
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
        let poller = SignalPoller(work: work, automatic: false, now: { clock.date })
        let a = UUID(), b = UUID()
        var published: [[UUID]] = []
        poller.onRead = { ids, _ in published.append(ids) }
        poller.replace([.init(id: a, sourceHost: "jira", readKey: "query", isJira: true, reader: reader),
                        .init(id: b, sourceHost: "jira", readKey: "query", isJira: true, reader: reader)])
        poller.tick(); await work.settled()
        #expect(await reader.calls.count == 1 && published.first?.count == 2)
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
        let poller = SignalPoller(work: work, automatic: false, now: { clock.date })
        var published = 0
        poller.onRead = { _, _ in published += 1 }
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

    @Test func stopDropsALateReadAndOverlappingTicksStartNoDuplicate() async {
        let clock = SignalPollClock(), entered = TestLatch(), release = TestLatch(), work = OperatorWork()
        let reader = SignalHeldReader(entered: entered, release: release)
        let poller = SignalPoller(work: work, automatic: false, now: { clock.date })
        var published = 0
        poller.onRead = { _, _ in published += 1 }
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
    var complete = true
    func setComplete(_ value: Bool) { complete = value }
    func poll(since: Date?, full: Bool) async throws -> SignalRead {
        calls.append(Call(since: since, full: full))
        return SignalRead(items: [], complete: complete, full: full)
    }
}
private struct SignalHeldReader: SignalSourceReader {
    var entered: TestLatch, release: TestLatch
    func poll(since: Date?, full: Bool) async throws -> SignalRead {
        entered.signal(); await release.wait()
        return SignalRead(items: [], complete: true)
    }
}
