import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct SignalForwardCompatibilityTests {
    @Test func anUnsupportedSavedCombinationDoesNotPreventSavingTheWorkspace() throws {
        var world = SignalWorld(); _ = world.signal()
        world.state.signals[0].start = SignalTrigger(source: .gitHub, query: "user-review-requested:@me")
        world.state.signals[0].finish = SignalFinish(mergesWhenReady: true)
        #expect(!world.state.signals[0].isRunnable)
        let folder = try ScratchFolder.make("aiterm-signal-future-")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = StateStore(url: folder.appendingPathComponent("state.json"))
        try store.save(world.state)
        #expect(try store.load() == world.state)
    }
    @Test func futureStringChoicesRoundTripAndRemainInert() throws {
        let raw: JSONValue = "from-a-newer-build"
        #expect(try JSONValue(encoding: raw.decode(SignalFinish.Then.self)) == raw)
        #expect(try JSONValue(encoding: raw.decode(SignalTrigger.Source.self)) == raw)
        #expect(try JSONValue(encoding: raw.decode(SignalSeen.Disposition.self)) == raw)
        var world = SignalWorld(); let signal = world.signal(), item = world.ticket().item
        var future = world.state.signals[0]
        future.start.source = try raw.decode(SignalTrigger.Source.self)
        #expect(!future.isRunnable)
        future.start.source = .jira; future.finish.then = try raw.decode(SignalFinish.Then.self)
        #expect(!future.isRunnable)
        let old = SignalSeen(signal: signal, item: item, disposition: .started, at: world.now)
        var object = try #require(JSONValue(encoding: old).objectValue); object["disposition"] = raw
        let seen = try JSONValue.object(object).decode(SignalSeen.self)
        let match = SignalMatch(signal: signal, item: item, project: world.project.id, matchedAt: world.now)
        #expect(MatchDecision.decide(matches: [match], signals: world.state.signals, tasks: [], seen: [seen], complete: true).isEmpty)
    }
    /// A kind or a Done source from a newer build is written back as it came and leaves the signal unable to run.
    @Test func aFutureKindOrDoneSourceRoundTripsAndCannotRun() throws {
        let raw: JSONValue = "team"
        #expect(try JSONValue(encoding: raw.decode(Signal.Kind.self)) == raw)
        var world = SignalWorld(); world.projectSignal()
        var object = try #require(JSONValue(encoding: world.state.signals[0]).objectValue)
        object["kind"] = raw
        let future = try JSONValue.object(object).decode(Signal.self)
        #expect(future.kind == .unknown("team") && !future.isProject && !future.isRunnable)
        #expect(try JSONValue(encoding: future) == .object(object))

        var done = try #require(JSONValue(encoding: world.state.signals[0]).objectValue)
        done["done"] = ["description": "", "query": "", "source": "someoneElse"]
        let later = try JSONValue.object(done).decode(Signal.self)
        #expect(later.done.source == .unknown("someoneElse") && later.isProject && !later.isRunnable)
        #expect(try JSONValue(encoding: later) == .object(done))
    }
}
