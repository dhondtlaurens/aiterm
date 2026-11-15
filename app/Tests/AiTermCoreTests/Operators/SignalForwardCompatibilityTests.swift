import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct SignalForwardCompatibilityTests {
    @Test func anUnsupportedSavedCombinationDoesNotPreventSavingTheWorkspace() throws {
        var world = SignalWorld(); _ = world.signal()
        world.state.signals[0].source = .gitHub(RequestConditions(event: .reviewRequested))
        world.state.signals[0].finish = SignalFinish(doneWhen: .approved, mergesWhenReady: true)
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
        #expect(try JSONValue(encoding: raw.decode(RequestConditions.Event.self)) == raw)
        #expect(try JSONValue(encoding: raw.decode(SignalSeen.Disposition.self)) == raw)
        let source: JSONValue = ["kind": "gitHub", "value": ["event": raw, "waitingOnMyReply": true, "sentBackToMe": true, "projects": []]]
        #expect(try !source.decode(SignalSource.self).isSupported)
        #expect(try JSONValue(encoding: source.decode(SignalSource.self)) == source)
        let finish: JSONValue = ["doneWhen": ["kind": "operatorJudges"], "then": raw, "mergesWhenReady": false, "deletesMergedBranch": false]
        #expect(try !finish.decode(SignalFinish.self).isValid(for: .jira(JiraConditions())))
        var world = SignalWorld(); let signal = world.signal(), item = world.ticket().item
        let old = SignalSeen(signal: signal, item: item, disposition: .started, at: world.now)
        var object = try #require(JSONValue(encoding: old).objectValue); object["disposition"] = raw
        let future = try JSONValue.object(object).decode(SignalSeen.self)
        let match = SignalMatch(signal: signal, item: item, project: world.project.id, matchedAt: world.now)
        #expect(MatchDecision.decide(matches: [match], signals: world.state.signals, tasks: [], seen: [future], complete: true).isEmpty)
    }
}
