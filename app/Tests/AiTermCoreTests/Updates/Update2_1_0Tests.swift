import Testing
import Foundation
@testable import AiTermCore

@Suite struct Update2_1_0Tests {
    private static func updated(_ state: JSONValue) throws -> JSONValue {
        var context = UpdateContext(state: state, defaults: ScratchDefaults.make(),
                                    supportDirectory: FileManager.default.temporaryDirectory, home: FileManager.default.temporaryDirectory)
        try UpdateScript.update2_1_0.run(&context)
        return context.state
    }

    /// A 2.0.0 workspace's saved snag reports go, and nothing else in the Operator's session changes.
    @Test func theOperatorsSnagsAreDropped() throws {
        let snag: JSONValue = ["key": "k", "title": "t", "showed": "s", "actual": "a", "workaround": "w",
                               "appVersion": "2.0.0", "at": "2026-11-20T08:00:00Z"]
        let before: JSONValue = ["version": "2.0.0", "items": [],
                                 "operatorSession": ["id": "S", "generation": 3, "questions": [], "snags": [snag]]]
        let after = try Self.updated(before)
        #expect(after == ["version": "2.0.0", "items": [], "operatorSession": ["id": "S", "generation": 3, "questions": []]])
        #expect(try Self.updated(after) == after)
    }

    /// A workspace without an Operator session, or with none saved, is left as it was.
    @Test func aWorkspaceWithoutAnOperatorSessionIsUntouched() throws {
        let none: JSONValue = ["version": "2.0.0", "items": []]
        #expect(try Self.updated(none) == none)
        let null: JSONValue = ["version": "2.0.0", "items": [], "operatorSession": .null]
        #expect(try Self.updated(null) == null)
    }
}
