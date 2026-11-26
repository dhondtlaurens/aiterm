import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The saved shape of signal kinds, "You decide" and the origin a signal leaves on an ordinary task: every kind is
/// saved, and an origin's optional fields are left out while they have nothing to say.
@Suite struct SignalKindFormatTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let request = ItemRef.request(remote: "https://git.example/shop/web", number: 7)

    @Test func anOperatorSignalSavesItsKind() throws {
        let (encoder, decoder) = SignalScheduleFormatTests.coder()
        let signal = Signal.make()
        #expect(signal.kind == .operator && !signal.isProject && signal.isRunnable)
        #expect(try JSONValue(encoding: signal)["kind"] == "operator")
        #expect(try decoder.decode(Signal.self, from: encoder.encode(signal)) == signal)
        var object = try #require(JSONValue(encoding: signal).objectValue); object["kind"] = nil
        #expect(throws: DecodingError.self) { try JSONValue.object(object).decode(Signal.self) }
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

    @Test func anOriginWithoutARequiredKeyFails() throws {
        let (encoder, decoder) = SignalScheduleFormatTests.coder()
        let origin = SignalOrigin.make(item: request, startedAt: now)
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(origin)) as? [String: Any])
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
