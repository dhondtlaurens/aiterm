import Testing
import Foundation
@testable import AiTermCore

@Suite struct Update2_0_0Tests {
    /// The workspace 1.5.0 saved for `SignalSavedFormatTests`, byte for byte: frozen, never re-recorded.
    static let saved150 = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/state-1.5.0.json")

    private static func updated(_ state: JSONValue) throws -> JSONValue {
        var context = UpdateContext(state: state, defaults: ScratchDefaults.make(),
                                    supportDirectory: FileManager.default.temporaryDirectory, home: FileManager.default.temporaryDirectory)
        try UpdateScript.update2_0_0.run(&context)
        return context.state
    }

    private static func decoded(_ state: JSONValue) throws -> AppState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppState.self, from: JSONEncoder().encode(state))
    }

    /// 1.5.0's file, with what an install could still hold beside it: retired signal dividers, the list
    /// before `items`, a task and its conversations from a retired agent, a GitLab issue, and an Oracle
    /// round saved under its old name. After the step, 2.0.0 reads all of it.
    @Test func aWorkspaceSavedBy150ReadsAfterTheStep() throws {
        var state = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.saved150))
        state["signalDividers"] = [["id": "E7A1C0DE-0000-4000-8000-0000000000F0", "name": "Later", "after": .null]]
        state["projects"] = []
        state["lastAgentByProject"] = ["E7A1C0DE-0000-4000-8000-000000000001", "grok", "E7A1C0DE-0000-4000-8000-000000000002", "codex"]
        state["lastModelByAgent"] = ["grok", "grok-5", "claude", "claude-opus-5-5"]
        state.edit("archive") { archive in
            archive.editEach { entry in
                entry.edit("task") { task in
                    task["agent"] = "grok"; task["model"] = "grok-5"; task["reasoning"] = "high"
                    task["conversations"] = [["agent": "grok", "id": "grok-chat"], ["agent": "claude", "id": "claude-chat"],
                                             ["agent": "claude", "id": "-flag"], ["agent": "codex", "id": ""]]
                    task["jira"] = ["key": "#7", "summary": "Issue", "url": "https://git.example/shop/web/-/issues/7",
                                    "source": ["gitLab": ["project": "shop/web"]]]
                }
            }
        }
        state.edit("operatorSession") { session in
            session["oracleRounds"] = [["id": "quiet", "tool": "answer_worker", "stage": "unchallenged",
                                        "unchallengedReason": "The Oracle is off.", "askedAt": "2026-11-14T12:00:00Z"]]
        }

        let after = try Self.updated(state)

        #expect(after["signalDividers"] == nil && after["projects"] == nil)
        let loaded = try Self.decoded(after)
        #expect(loaded.tasks.map(\.kind) == [.task, .task])
        #expect(loaded.tasks[1].conversations.isEmpty && loaded.tasks[1].takenOver)
        #expect(loaded.tasks[0].jira?.source == .jira)
        #expect(loaded.signals.allSatisfy { $0.kind == .operator })
        #expect(loaded.tasks[0].signalTask?.current.configuration.kind == .operator)
        #expect(loaded.tasks[0].signalTask?.pendingStages.allSatisfy { $0.configuration.kind == .operator } == true)
        let former = try #require(loaded.archive.first?.task)
        #expect(former.agent == .claude && former.model == "" && former.reasoning == nil)
        #expect(former.conversations == [TaskConversation(agent: .claude, id: "claude-chat")])
        #expect(former.jira?.source == .gitLab(project: "shop/web"))
        #expect(loaded.lastAgentByProject == [UUID(uuidString: "E7A1C0DE-0000-4000-8000-000000000002")!: .codex])
        #expect(loaded.lastModelByAgent == [.claude: "claude-opus-5-5"])
        let round = try #require(loaded.operatorSession?.oracleRounds.first)
        #expect(round.stage == .unanswered && round.unansweredReason == "The Oracle is off.")
        #expect(loaded.scheduleCursors.isEmpty && loaded.operatorFolded.isEmpty && !loaded.operatorOpen)
    }

    /// The proof the steps are whole: 1.5.0's own file of `SignalSavedFormatTests`' workspace, updated
    /// the way a launch does it (2.0.0, then 2.1.0), reads as that workspace, and a save writes the
    /// current golden byte for byte.
    @Test func the150GoldenBecomesTheCurrentGolden() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        try FileManager.default.copyItem(at: Self.saved150, to: url)
        let updater = WorkspaceUpdater(url: url)
        #expect(try updater.plan() == .update(from: ReleaseVersion(major: 1, minor: 5, patch: 0),
                                              steps: [ReleaseVersion(major: 2, minor: 0, patch: 0), ReleaseVersion(major: 2, minor: 1, patch: 0)]))

        try updater.run(defaults: ScratchDefaults.make(), home: dir)

        let store = StateStore(url: url)
        let loaded = try store.load()
        #expect(loaded == SignalSavedFormatTests.state())
        let golden = Self.saved150.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Operators/Fixtures/operator-signals/state.json")
        #expect(try store.encoded(loaded) == Data(contentsOf: golden))
        #expect(try Data(contentsOf: updater.beforeUpdateURL(from: UpdateScripts.baseline)) == Data(contentsOf: Self.saved150))
    }

    /// The smallest file 1.5.0 wrote, for a workspace with nothing in it yet.
    @Test func anEmptyWorkspaceReads() throws {
        let loaded = try Self.decoded(Self.updated(["items": [], "tasks": [], "terminals": [], "lastAgentByProject": [], "lastModelByAgent": []]))
        #expect(loaded == .empty)
    }

    /// The step runs once per workspace, but running it twice changes nothing more.
    @Test func runningTheStepAgainChangesNothing() throws {
        let once = try Self.updated(JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.saved150)))
        #expect(try Self.updated(once) == once)
    }
}
