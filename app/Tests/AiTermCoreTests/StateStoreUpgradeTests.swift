import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// A workspace saved by the previous release holds Operator records this build cannot read. It
/// opens without them, everything else as it was, with the file kept beside it under a dated name.
@Suite struct StateStoreUpgradeTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Operators/Fixtures/operator-signals")

    @Test(arguments: ["state-0.58.json", "operator-session-0.58.json"])
    func aPreviousReleaseWorkspaceOpensWithoutItsOperatorRecords(_ name: String) throws {
        let original = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        let (folder, store) = try Self.store(holding: original)
        defer { try? FileManager.default.removeItem(at: folder) }

        let loaded = try store.load()

        #expect(store.clearedOperatorRecords)
        #expect(loaded.operatorSession == nil)
        #expect(loaded.tasks.allSatisfy { $0.signalTask == nil } && loaded.archive.allSatisfy { $0.task.signalTask == nil })
        let expected = try Self.withoutOperatorRecords(original)
        #expect(loaded.projects == expected.projects && !loaded.projects.isEmpty)
        #expect(loaded.tasks == expected.tasks && !loaded.tasks.isEmpty)
        #expect(loaded.archive == expected.archive)
        #expect(loaded.signals == expected.signals && loaded.signalSeen == expected.signalSeen)
        #expect(loaded.terminals == expected.terminals)
        #expect(loaded == expected)
        let copies = try Self.datedCopies(in: folder)
        #expect(copies.count == 1)
        #expect(try Data(contentsOf: #require(copies.first)) == original)
        #expect(copies.first?.lastPathComponent.wholeMatch(of: /state\.json\.before-reset-\d{8}-\d{6}/) != nil)
        let primary = try Data(contentsOf: store.url)
        #expect(try Self.decoder.decode(AppState.self, from: primary) == loaded, "the primary on disk now decodes")

        let again = StateStore(url: store.url)
        #expect(try again.load() == loaded)
        #expect(!again.clearedOperatorRecords)
        #expect(try Data(contentsOf: store.url) == primary)
        #expect(try Self.datedCopies(in: folder).count == 1)

        var next = loaded
        next.lastModelByAgent[.claude] = "sonnet"
        try store.save(next)
        #expect(try StateStore(url: store.url).load() == next)
        #expect(store.hasValidBackup, "a backup in the previous release's shape does not block a restore")
    }

    @Test func theDrivenTasksKeepTheirTitlesBranchesAndConversations() throws {
        let (folder, store) = try Self.store(holding: Data(contentsOf: Self.fixtures.appendingPathComponent("state-0.58.json")))
        defer { try? FileManager.default.removeItem(at: folder) }
        let state = try store.load()
        #expect(state.tasks.map(\.title) == ["Make retries safe"] && state.tasks.map(\.branch) == ["feat/pay-1"])
        #expect(state.tasks.first?.conversations.map(\.id) == ["worker-conversation"])
        #expect(state.archive.map(\.task.title) == ["Earlier work"])
        #expect(state.signals.count == 2 && state.signalSeen.count == 1)
    }

    @Test func aTakenOverRecordMarksItsTask() throws {
        var json = try Self.json(Data(contentsOf: Self.fixtures.appendingPathComponent("state-0.58.json")))
        var tasks = try #require(json["tasks"] as? [[String: Any]])
        var record = try #require(tasks[0]["signalTask"] as? [String: Any])
        record["takenOver"] = true
        tasks[0]["signalTask"] = record
        json["tasks"] = tasks
        let (folder, store) = try Self.store(holding: JSONSerialization.data(withJSONObject: json))
        defer { try? FileManager.default.removeItem(at: folder) }

        let loaded = try store.load()

        #expect(loaded.tasks[0].takenOver && loaded.tasks[0].signalTask == nil)
        #expect(!loaded.archive[0].task.takenOver, "an archived task whose record was not taken over gains nothing")
    }

    @Test func aCurrentWorkspaceIsUntouched() throws {
        let original = try Data(contentsOf: Self.fixtures.appendingPathComponent("state.json"))
        let (folder, store) = try Self.store(holding: original)
        defer { try? FileManager.default.removeItem(at: folder) }

        let loaded = try store.load()

        #expect(!store.clearedOperatorRecords)
        #expect(loaded.operatorSession != nil && loaded.tasks.contains { $0.signalTask != nil })
        #expect(try Data(contentsOf: store.url) == original)
        #expect(try Self.datedCopies(in: folder).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.backupURL.path))
    }

    @Test func aWorkspaceBrokenElsewhereStillFailsToLoad() throws {
        var json = try Self.json(Data(contentsOf: Self.fixtures.appendingPathComponent("state-0.58.json")))
        var items = try #require(json["items"] as? [[String: Any]])
        var project = try #require(items[0]["project"] as? [String: Any])
        project["path"] = nil
        items[0]["project"] = project
        json["items"] = items
        let original = try JSONSerialization.data(withJSONObject: json)
        let (folder, store) = try Self.store(holding: original)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(throws: DecodingError.self) { try store.load() }

        #expect(!store.clearedOperatorRecords)
        #expect(try Data(contentsOf: store.url) == original)
        #expect(try Self.datedCopies(in: folder).isEmpty)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func store(holding data: Data) throws -> (URL, StateStore) {
        let folder = try ScratchFolder.make("aiterm-upgrade-")
        let store = StateStore(url: folder.appendingPathComponent("state.json"))
        try data.write(to: store.url)
        return (folder, store)
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The file as the reset script leaves it: no session, no task records, nothing else changed.
    private static func withoutOperatorRecords(_ data: Data) throws -> AppState {
        var json = try json(data)
        json["operatorSession"] = nil
        let clear: ([String: Any]) -> [String: Any] = { var task = $0; task["signalTask"] = nil; return task }
        json["tasks"] = (json["tasks"] as? [[String: Any]])?.map(clear)
        json["archive"] = (json["archive"] as? [[String: Any]])?.map { var entry = $0; entry["task"] = (entry["task"] as? [String: Any]).map(clear); return entry }
        return try decoder.decode(AppState.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private static func datedCopies(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("state.json.before-reset-") }
    }
}
