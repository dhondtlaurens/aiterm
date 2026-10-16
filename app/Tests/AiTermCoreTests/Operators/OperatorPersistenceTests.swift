import Testing
import Foundation
@testable import AiTermCore

/// `state.json` gains `runs` and `TaskItem.operated` (spec §5.1). A workspace saved before either
/// existed loads as it was and is written back unchanged; one with both survives a save and a load;
/// and a run or an operated task only a newer build can read is kept whole, not dropped.
@Suite struct OperatorPersistenceTests {
    private func scratchStore() -> (StateStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (StateStore(url: dir.appendingPathComponent("state.json")), dir)
    }

    @Test func aWorkspaceWithRunsAndOperatedTasksRoundTripsThroughTheStore() throws {
        let (store, dir) = scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let parent = OperatorFixtures.task("PLUTO-230", .accepted)
        let child = OperatorFixtures.task("PLUTO-231", .queued, dependsOn: [TaskDependency(task: parent.id, kind: .code)])
        var state = OperatorFixtures.state(OperatorFixtures.run(), [parent, child])
        state.tasks[0].operated?.acceptance = OperatorFixtures.acceptance()
        state.runs[0].questions = [OperatorQuestion(id: "q", text: "Which?", task: child.id, askedAt: OperatorFixtures.epoch)]

        try store.save(state)

        #expect(try store.load() == state)
    }

    /// A file from before operators: no `runs`, no `operated`. It loads with none, and a save
    /// writes neither key, so an older build reading it back sees the file it always wrote.
    @Test func aWorkspaceFromBeforeOperatorsLoadsAndIsWrittenWithoutTheNewKeys() throws {
        let (store, dir) = scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        {"items":[{"kind":"project","project":{"id":"0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9","name":"Shop","path":"/tmp/shop",
         "provider":"git","addedAt":"1970-01-01T00:00:00Z","collapsed":false}}],
         "tasks":[{"id":"9F1C5B4E-3A2D-4C7F-8E10-2B6D9A0C1E33","projectId":"0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9",
         "title":"Gift card","branch":"feat/gift","worktreePath":"/tmp/wt","baseBranch":"main","agent":"claude",
         "model":"opus","appendTicket":false,"createdAt":"1970-01-01T00:00:00Z"}],"terminals":[]}
        """
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.url)

        let loaded = try store.load()
        #expect(loaded.runs.isEmpty)
        #expect(loaded.tasks.first?.operated == nil)

        try store.save(loaded)
        let written = String(decoding: try Data(contentsOf: store.url), as: UTF8.self)
        #expect(!written.contains("\"runs\""))
        #expect(!written.contains("\"operated\""))
    }

    /// `state.json` is shared by every build on the machine: a run whose state only a newer build
    /// knows, and a task whose workflow state is one, still load — the task as one you made — and a
    /// save writes both back as they came.
    @Test func aRunAndAnOperatedTaskFromANewerBuildSurviveAResave() throws {
        let (store, dir) = scratchStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let known = OperatorFixtures.run()
        let task = OperatorFixtures.task("PLUTO-1", .working)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(OperatorFixtures.state(known, [task]))) as? [String: Any])
        var newer = try #require(JSONSerialization.jsonObject(with: encoder.encode(known)) as? [String: Any])
        newer["id"] = UUID().uuidString
        newer["state"] = "hibernating"
        json["runs"] = try #require(json["runs"] as? [Any]) + [newer]
        var tasks = try #require(json["tasks"] as? [[String: Any]])
        var operated = try #require(tasks[0]["operated"] as? [String: Any])
        operated["state"] = "inReview"
        tasks[0]["operated"] = operated
        json["tasks"] = tasks
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: store.url)

        let loaded = try store.load()
        #expect(loaded.runs == [known])
        #expect(loaded.tasks.count == 1 && loaded.tasks[0].operated == nil)

        try store.save(loaded)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? NSDictionary)
        let runs = try #require(saved["runs"] as? [NSDictionary])
        #expect(runs.count == 2 && runs[1]["state"] as? String == "hibernating")
        let savedTask = try #require((saved["tasks"] as? [NSDictionary])?.first)
        #expect((savedTask["operated"] as? NSDictionary)?["state"] as? String == "inReview")
    }

    /// Assigning `operated` replaces what the file had: the unreadable value is not written back
    /// over the one you just set.
    @Test func assigningOperatedReplacesAnUnreadableOne() throws {
        let task = OperatorFixtures.task("PLUTO-1", .working)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(task)) as? [String: Any])
        var operated = try #require(json["operated"] as? [String: Any])
        operated["end"] = "deploy"
        json["operated"] = operated
        var loaded = try JSONDecoder().decode(TaskItem.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(loaded.operated == nil)

        loaded.operated = OperatorFixtures.operated("PLUTO-1", .queued)
        let again = try JSONDecoder().decode(TaskItem.self, from: JSONEncoder().encode(loaded))

        #expect(again.operated == OperatorFixtures.operated("PLUTO-1", .queued))
    }
}
