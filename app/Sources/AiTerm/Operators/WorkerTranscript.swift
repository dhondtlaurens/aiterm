import Foundation
import Synchronization
import AiTermCore

/// The last thing a worker said, read from its agent's own conversation file — never the screen, where
/// Claude's grey suggestion reads as typed text (spec §2.2). Claude keeps a conversation in
/// `projects/<folder>/<id>.jsonl` under its configuration folder (`ClaudeConfig`: `~/.claude` unless
/// `CLAUDE_CONFIG_DIR` names another), Codex in `~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-…-<id>.jsonl`;
/// both are named by the conversation id the daemon reports (`SessionInfo.conversationId`).
enum WorkerTranscript {
    /// How much of a conversation's end is read: a reply is kilobytes, the file can be megabytes.
    static let tailBytes = 512 * 1024

    /// The conversation's file under `home`, if there is one. An id that could name a path finds none.
    static func file(agent: AgentKind, conversation: String, home: URL, claudeConfig: ClaudeConfig) -> URL? {
        guard TaskConversation.isResumable(conversation), !conversation.contains("/"), !conversation.contains("..") else { return nil }
        let fileManager = FileManager.default
        switch agent {
        case .claude:
            let projects = claudeConfig.directory(home: home).appendingPathComponent("projects")
            let folders = (try? fileManager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            return folders.map { $0.appendingPathComponent(conversation + ".jsonl") }.first { fileManager.fileExists(atPath: $0.path) }
        case .codex:
            guard let walk = fileManager.enumerator(at: home.appendingPathComponent(".codex/sessions"), includingPropertiesForKeys: nil)
            else { return nil }
            for case let url as URL in walk
            where url.lastPathComponent.hasPrefix("rollout-") && url.lastPathComponent.hasSuffix("-\(conversation).jsonl") {
                return url
            }
            return nil
        case .pi:
            return nil
        }
    }

    /// When the file was last written: how far the worker's conversation has grown, without reading it.
    static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// The newest reply in the file's last `tailBytes`, read from the end.
    static func lastMessage(in file: URL, agent: AgentKind) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        // A read that starts mid-file starts mid-line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        let decoder = JSONDecoder()
        for line in lines.reversed() {
            guard let record = try? decoder.decode(JSONValue.self, from: Data(line.utf8)),
                  let text = agent == .codex ? codexReply(record) : claudeReply(record), !text.isEmpty else { continue }
            return text
        }
        return nil
    }

    /// An assistant record's text blocks, joined; a record of tool calls alone says nothing.
    static func claudeReply(_ record: JSONValue) -> String? {
        guard record["type"]?.stringValue == "assistant", let content = record["message"]?["content"]?.arrayValue else { return nil }
        let texts = content.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Codex's `agent_message` event, or an assistant message's output text.
    static func codexReply(_ record: JSONValue) -> String? {
        let payload = record["payload"]
        if record["type"]?.stringValue == "event_msg", payload?["type"]?.stringValue == "agent_message" {
            return payload?["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard record["type"]?.stringValue == "response_item", payload?["type"]?.stringValue == "message",
              payload?["role"]?.stringValue == "assistant", let content = payload?["content"]?.arrayValue else { return nil }
        let texts = content.compactMap { $0["type"]?.stringValue == "output_text" ? $0["text"]?.stringValue : nil }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Where each worker conversation's transcript is, found once and kept for the Operator's readers (`BranchWatch`,
/// `WorkerTurnReader`, `WorkerQuietWatch`, `read_task`): a lookup lists Claude's project folders or walks every Codex
/// session, so a file found is used again while it is still there, and looked up afresh once it is not. Under the
/// `home` and the Claude folder (`ClaudeConfig`) AiTerm is set to. Blocking: read off the main actor.
final class TranscriptLocator: Sendable {
    let home: URL
    let claudeConfig: ClaudeConfig
    private let found = Mutex<[String: URL]>([:])

    init(home: URL, claudeConfig: ClaudeConfig) {
        self.home = home
        self.claudeConfig = claudeConfig
    }

    /// The conversation's file, as `WorkerTranscript.file` finds it.
    func file(agent: AgentKind, conversation: String) -> URL? {
        let key = agent.rawValue + "/" + conversation
        if let known = found.withLock({ $0[key] }), FileManager.default.fileExists(atPath: known.path) { return known }
        let file = WorkerTranscript.file(agent: agent, conversation: conversation, home: home, claudeConfig: claudeConfig)
        found.withLock { $0[key] = file }
        return file
    }

    /// The worker's last message in its conversation's file (`WorkerTranscript.lastMessage(in:agent:)`).
    func lastMessage(agent: AgentKind, conversation: String) -> String? {
        file(agent: agent, conversation: conversation).flatMap { WorkerTranscript.lastMessage(in: $0, agent: agent) }
    }
}
