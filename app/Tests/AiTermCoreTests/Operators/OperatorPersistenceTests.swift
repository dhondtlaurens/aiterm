import Testing
import Foundation
@testable import AiTermCore

/// Supported workspace saves retain Operator ownership, plan state and completion evidence.
@Suite struct OperatorPersistenceTests {
    private func scratchStore() -> (StateStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (StateStore(url: dir.appendingPathComponent("state.json")), dir)
    }

    @Test func aWorkspaceWithRunsAndOperatedTasksRoundTripsThroughTheStore() throws {
        let (store, dir) = scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let parent = OperatorFixtures.task("PLUTO-230", .accepted)
        let child = OperatorFixtures.task("PLUTO-231", .inReview, dependsOn: [TaskDependency(task: parent.id, kind: .code)])
        var state = OperatorFixtures.state(OperatorFixtures.run(), [parent, child])
        state.tasks[0].operated?.acceptance = OperatorFixtures.acceptance()
        state.tasks[1].operated?.modelReason = "The schema needs care."
        state.runs[0].questions = [OperatorQuestion(id: "q", text: "Which?", task: child.id, askedAt: OperatorFixtures.epoch)]
        state.runs[0].finds = [OffBriefFind(key: "leak", title: "A token in the logs", why: "It leaks a secret.", ticket: nil)]

        try store.save(state)

        #expect(try store.load() == state)
    }

    @Test(arguments: ["run", "task"])
    func anUnreadableOperatorRecordCannotSilentlyBecomeAManualTask(record: String) throws {
        let (store, dir) = scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = OperatorFixtures.state(OperatorFixtures.run(), [OperatorFixtures.task("A", .working)])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any])
        if record == "run" {
            var runs = try #require(json["runs"] as? [[String: Any]])
            runs[0]["state"] = "invalid-state"
            json["runs"] = runs
        } else {
            var tasks = try #require(json["tasks"] as? [[String: Any]])
            var operated = try #require(tasks[0]["operated"] as? [String: Any])
            operated["end"] = "invalid-end"
            tasks[0]["operated"] = operated
            json["tasks"] = tasks
        }
        let bytes = try JSONSerialization.data(withJSONObject: json)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try bytes.write(to: store.url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.save(state) }
        #expect(try Data(contentsOf: store.url) == bytes)
    }

    /// The summary, its times and the end time are all kept, and a run saved without them reads them as none.
    @Test func theSummaryFieldsRoundTrip() throws {
        var run = OperatorFixtures.run(state: .stopped)
        run.summary = "All done."; run.summaryAt = OperatorFixtures.epoch.addingTimeInterval(60)
        run.completedAt = OperatorFixtures.epoch.addingTimeInterval(30); run.summaryGivenUp = true
        run.endedAt = OperatorFixtures.epoch.addingTimeInterval(90)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

        #expect(try decoder.decode(OperatorRun.self, from: encoder.encode(run)) == run)
    }

    @Test func aRunWithoutThemDecodes() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let json = try #require(JSONSerialization.jsonObject(with: encoder.encode(OperatorFixtures.run())) as? [String: Any])
        for key in ["summary", "summaryAt", "completedAt", "summaryGivenUp", "endedAt"] {
            #expect(json[key] == nil, "a run that never had one writes no \(key)")
        }

        let run = try decoder.decode(OperatorRun.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(run.summary == nil && run.summaryAt == nil && run.completedAt == nil && run.endedAt == nil && !run.summaryGivenUp)
    }
}
