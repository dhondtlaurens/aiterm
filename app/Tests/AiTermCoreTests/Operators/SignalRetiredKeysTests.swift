import Foundation
import Testing
@testable import AiTermCore

@Suite struct SignalRetiredKeysTests {
    @Test func anOldWorkspaceLoadsAndItsNextSaveDropsEveryBroadcastKey() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("AiTermTests/Fixtures/operator-saved-format/state.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var old = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        old["foldedRuns"] = ["E7A1C0DE-0000-4000-8000-000000000001"]
        let state = try decoder.decode(AppState.self, from: JSONSerialization.data(withJSONObject: old))
        let oldIDs = (old["tasks"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        #expect(state.tasks.map { $0.id.uuidString } == oldIDs)
        #expect(!state.tasks.isEmpty)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let json = try #require(JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any])
        #expect(json["runs"] == nil)
        #expect(json["foldedRuns"] == nil)
        let tasks = try #require(json["tasks"] as? [[String: Any]])
        #expect(tasks.allSatisfy { $0["operated"] == nil })
        let archive = json["archive"] as? [[String: Any]] ?? []
        #expect(archive.allSatisfy { ($0["task"] as? [String: Any])?["operated"] == nil })
    }
}
