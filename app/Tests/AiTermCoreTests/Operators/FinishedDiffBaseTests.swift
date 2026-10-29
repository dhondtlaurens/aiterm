import Foundation
import Testing
@testable import AiTermCore

/// Auto-close's diff base: kept on the live task from its acceptance, carried into its finished record at close.
@Suite struct FinishedDiffBaseTests {
    private func saved<T: Encodable>(_ value: T) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test func aTasksDiffBaseRoundTripsAndIsLeftOutWhileEmpty() throws {
        var task = OperatedTask(runId: UUID(), key: "A", brief: "Work", revision: 1)
        #expect(try saved(task)["diffBaseSHA"] == nil)
        task.diffBaseSHA = "parent-commit"
        #expect(try JSONDecoder().decode(OperatedTask.self, from: JSONEncoder().encode(task)).diffBaseSHA == "parent-commit")
    }

    @Test func aRecordsDiffBaseRoundTripsAndIsOptional() throws {
        var record = FinishedTaskRecord(task: UUID(), key: "A", title: "Work", ticket: nil, project: UUID(), agent: .codex,
                                        model: "m", reasoning: nil, end: .commit, state: .accepted, acceptedSHA: "4f2a91c",
                                        branch: "task", mergeRequestURL: nil, mergedSHA: nil, result: "accepted",
                                        branchDeleted: false, at: Date(timeIntervalSince1970: 0))
        #expect(record.diffBaseSHA == nil)
        #expect(try saved(record)["diffBaseSHA"] == nil)
        record.diffBaseSHA = "parent-commit"
        #expect(try JSONDecoder().decode(FinishedTaskRecord.self, from: JSONEncoder().encode(record)).diffBaseSHA == "parent-commit")
    }
}
