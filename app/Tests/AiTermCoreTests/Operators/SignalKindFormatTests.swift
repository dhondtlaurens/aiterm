import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The saved shape of signal kinds, "You decide" and the origin a signal leaves on an ordinary task: what was saved
/// before decodes and saves unchanged, and every new field is left out while it has nothing to say.
@Suite struct SignalKindFormatTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let request = ItemRef.request(remote: "https://git.example/shop/web", number: 7)

    @Test func aSignalSavedBeforeKindsIsAnOperatorSignalAndSavesUnchanged() throws {
        let (encoder, decoder) = SignalScheduleFormatTests.coder()
        let signal = try decoder.decode(Signal.self, from: Data(SignalScheduleFormatTests.oldSignal.utf8))
        #expect(signal.kind == nil && !signal.isProject && signal.isRunnable)
        let again = try JSONSerialization.jsonObject(with: encoder.encode(signal)) as? NSDictionary
        let before = try JSONSerialization.jsonObject(with: Data(SignalScheduleFormatTests.oldSignal.utf8)) as? NSDictionary
        #expect(again == before)
        // An Operator signal made as one saves no kind either.
        let made = Signal(name: "Plan", createdAt: now, start: signal.start, done: signal.done, work: signal.work,
                          agents: signal.agents, finish: signal.finish, kind: .operator)
        let saved = try JSONValue(encoding: made)
        #expect(made.kind == nil && saved["kind"] == nil)
    }

    @Test func aProjectSignalLeavingDoneToThePersonRoundTrips() throws {
        let (encoder, decoder) = SignalScheduleFormatTests.coder()
        let signal = Signal.project(createdAt: now)
        #expect(signal.isProject && signal.isRunnable)
        let saved = try JSONValue(encoding: signal)
        #expect(saved["kind"] == "project" && saved["done"]?["source"] == "person")
        #expect(try decoder.decode(Signal.self, from: encoder.encode(signal)) == signal)
    }

    @Test func anOriginWithEveryFieldRoundTrips() throws {
        let (encoder, decoder) = SignalScheduleFormatTests.coder()
        var origin = SignalOrigin(signal: UUID(), name: "Reviews for me", item: request, startedAt: now,
                                  earlier: [SignalStep(signal: UUID(), name: "Plan tickets", at: now.addingTimeInterval(-60))],
                                  owed: OwedPrompt(text: "/psg:peer-review", at: now, kind: .delivery))
        origin.doneKey = "gitLab\nreviewer:@me -review-state:unreviewed"; origin.doneMatched = false
        origin.doneAt = now.addingTimeInterval(120); origin.thenApplied = false; origin.thenNote = "Unsaved work."
        origin.turn = SignalTurn(sentAt: now, pastedAt: now.addingTimeInterval(1), seenWorking: true)
        origin.notifiedAt = now.addingTimeInterval(180)
        let data = try encoder.encode(origin)
        #expect(try decoder.decode(SignalOrigin.self, from: data) == origin)
        let saved = try JSONValue(encoding: origin)
        #expect(saved["owed"]?["kind"] == "delivery")
        let launch = try JSONValue(encoding: OwedPrompt(text: "go", at: now, kind: .launch))
        #expect(launch["kind"] == "launch")
    }

    @Test func anOriginWithOnlyItsRequiredFieldsSavesOnlyThose() throws {
        let (encoder, decoder) = SignalScheduleFormatTests.coder()
        let origin = SignalOrigin.make(item: request, startedAt: now)
        let data = try encoder.encode(origin)
        #expect(try decoder.decode(SignalOrigin.self, from: data) == origin)
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == ["signal", "name", "item", "startedAt"])
        let turn = try #require(JSONSerialization.jsonObject(with: encoder.encode(SignalTurn())) as? [String: Any])
        #expect(turn.isEmpty)
    }

    /// A newer build's extra key is ignored; a missing required one fails, as every record does at this boundary.
    @Test func anOriginFromANewerBuildReadsUnlessARequiredKeyIsMissing() throws {
        let (encoder, decoder) = SignalScheduleFormatTests.coder()
        let origin = SignalOrigin.make(item: request, startedAt: now)
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(origin)) as? [String: Any])
        object["fromLater"] = ["any": 1]
        #expect(try decoder.decode(SignalOrigin.self, from: JSONSerialization.data(withJSONObject: object)) == origin)
        object["name"] = nil
        #expect(throws: DecodingError.self) { try decoder.decode(SignalOrigin.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func aTaskWritesItsOriginOnlyWhenItHasOne() throws {
        let (encoder, decoder) = SignalScheduleFormatTests.coder()
        var task = TaskItem.make(project: UUID(), branch: "review/7")
        let plain = try encoder.encode(task)
        #expect(!String(decoding: plain, as: UTF8.self).contains("signalOrigin"))
        #expect(try decoder.decode(TaskItem.self, from: plain).signalOrigin == nil)
        task.signalOrigin = SignalOrigin.make(item: request, startedAt: now)
        let marked = try decoder.decode(TaskItem.self, from: encoder.encode(task))
        #expect(marked == task && marked.signalOrigin != nil && marked.signalTask == nil)
    }

    @Test func aRecordWritesItsChainOnlyWhenItHasOne() throws {
        let (encoder, decoder) = SignalScheduleFormatTests.coder()
        var record = SignalTask.make(item: request, startedAt: now)
        #expect(!String(decoding: try encoder.encode(record), as: UTF8.self).contains("earlier"))
        record.earlier = [SignalStep(signal: UUID(), name: "Plan tickets", at: now)]
        #expect(try decoder.decode(SignalTask.self, from: encoder.encode(record)) == record)
    }
}
