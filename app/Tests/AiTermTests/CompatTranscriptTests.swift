import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore

/// The compatibility check's captures (`daemon/tests/fixtures/compat/`, `scripts/compat-check.sh`)
/// read by the Operator's transcript reader, which lives in the app: the last thing a Claude Code or
/// Codex worker said, from its own conversation file, found by the conversation id its hooks posted.
@Suite struct CompatTranscriptTests {
    static let captures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("daemon/tests/fixtures/compat")

    /// The conversation the capture's first prompt went to, as its UserPromptSubmit named it: the
    /// main session, where the scripted turns ran.
    static func conversation(_ agent: AgentKind) throws -> String {
        let posts = try String(contentsOf: captures.appendingPathComponent("\(agent.rawValue)/posts.jsonl"), encoding: .utf8)
        for line in posts.split(separator: "\n") {
            let post = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            if let body = post?["body"] as? [String: Any], body["hook_event_name"] as? String == "UserPromptSubmit",
               let id = body["session_id"] as? String {
                return id
            }
        }
        Issue.record("the \(agent.rawValue) capture names no UserPromptSubmit")
        throw CancellationError()
    }

    @Test func claudesConversationFileGivesItsLastReply() throws {
        let config = ClaudeConfig(Self.captures.appendingPathComponent("claude").path)
        let file = try #require(WorkerTranscript.file(agent: .claude, conversation: try Self.conversation(.claude),
                                                      home: FileManager.default.temporaryDirectory, claudeConfig: config),
                                "the conversation is not at projects/<folder>/<id>.jsonl")
        let reply = WorkerTranscript.lastMessage(in: file, agent: .claude)
        #expect(reply?.isEmpty == false, "no assistant reply reads from Claude's conversation file")
    }

    @Test func codexsRolloutGivesItsLastReply() throws {
        // WorkerTranscript looks under <home>/.codex/sessions; the capture keeps them at codex/sessions.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("compat-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".codex"),
                                                   withDestinationURL: Self.captures.appendingPathComponent("codex"))
        let file = try #require(WorkerTranscript.file(agent: .codex, conversation: try Self.conversation(.codex), home: home,
                                                      claudeConfig: ClaudeConfig()),
                                "the rollout is not at sessions/<yyyy>/<mm>/<dd>/rollout-…-<id>.jsonl")
        let reply = WorkerTranscript.lastMessage(in: file, agent: .codex)
        #expect(reply?.isEmpty == false, "no assistant reply reads from Codex's rollout")
    }
}
