import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The saved shape of scheduled signals and the Operator Done: the schedule, the Operator Done and a run round-trip.
@Suite struct SignalScheduleFormatTests {
    static func coder() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601; decoder.dateDecodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (encoder, decoder)
    }

    @Test func aScheduledSignalWithAnOperatorDoneRoundTrips() throws {
        let (encoder, decoder) = Self.coder()
        var world = SignalWorld()
        let id = world.scheduled(merges: true)
        let signal = try #require(world.state.signal(id: id))
        #expect(signal.isScheduled && signal.isRunnable && signal.start.cron?.expression == "0 9 * * 1")
        let data = try encoder.encode(signal)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""source":"schedule""#) && text.contains(#""source":"operator""#))
        #expect(text.contains(#""project":""#) && text.contains(#""scheduledFrom":""#))
        #expect(try decoder.decode(Signal.self, from: data) == signal)
    }

    @Test func aRunItemAndItsTaskOriginRoundTrip() throws {
        let (encoder, decoder) = Self.coder()
        let run = SignalRunRef(signal: UUID(uuidString: "E7A1C0DE-0000-4000-8000-000000000009")!, at: Date(timeIntervalSince1970: 1_800_000_000))
        let item = ItemRef.run(run)
        #expect(item.identity == "run:E7A1C0DE-0000-4000-8000-000000000009:2027-01-15T08:00:00Z")
        let saved = try JSONValue(encoding: item)
        #expect(saved["kind"] == "run")
        #expect(try saved.decode(ItemRef.self) == item)
        var record = SignalTask.make(item: item)
        record.scheduledRun = run
        #expect(try decoder.decode(SignalTask.self, from: encoder.encode(record)) == record)
        // A task no schedule started carries no run.
        let plain = SignalTask.make(item: .ticket(site: "https://jira.example", key: "PAY-1"))
        #expect(!String(decoding: try encoder.encode(plain), as: UTF8.self).contains("scheduledRun"))
    }

    @Test func scheduleCursorsAreAlwaysSaved() throws {
        let (encoder, decoder) = Self.coder()
        var state = AppState()
        let plain = try #require(JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any])
        #expect(plain["scheduleCursors"] != nil)
        let id = UUID()
        state.scheduleCursors[id] = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try decoder.decode(AppState.self, from: encoder.encode(state)).scheduleCursors == state.scheduleCursors)
    }

    @Test(arguments: [
        (SignalTrigger(source: .schedule, query: "0 9 * * 1"), true, "Choose a project for its runs."),
        (SignalTrigger(source: .schedule, query: "0 9 * * Mo", project: UUID()), true, "“Mo” isn’t a weekday: use 0–6 or MON–SUN."),
        (SignalTrigger(source: .schedule, query: "0 9 * * 1", project: UUID()), false, "A schedule can only start a signal."),
        (SignalTrigger(source: .operator, query: ""), true, "The Operator decides only when a signal is done."),
    ])
    func newKindsRefuseTheWrongPlace(_ trigger: SignalTrigger, _ start: Bool, _ message: String) {
        #expect(trigger.refusal(start: start)?.message == message)
    }

    @Test func anOperatorDoneNeedsNoQueryAndAScheduleNoJiraDone() {
        #expect(SignalTrigger(source: .operator, query: "").refusal(start: false) == nil)
        var world = SignalWorld()
        world.scheduled(done: SignalTrigger(source: .jira, query: "status = Done"))
        #expect(world.state.signals[0].isValid == false)
        world.state.signals[0].done = SignalTrigger(source: .gitLab, query: "state:merged")
        #expect(world.state.signals[0].isValid)
        // A merge is offered on a schedule: its runs' merge requests are the person's own.
        #expect(world.state.signals[0].start.offersMerge)
    }
}
