import Foundation
import CryptoKit
import Synchronization
import AiTermCore

/// The last thing a worker said, read from its agent's own conversation file — never the screen, where
/// Claude's grey suggestion reads as typed text. Claude keeps a conversation in
/// `projects/<folder>/<id>.jsonl` under its configuration folder (`ClaudeConfig`: `~/.claude` unless
/// `CLAUDE_CONFIG_DIR` names another), Codex in `~/.codex/sessions/<yyyy>/<mm>/<dd>/rollout-…-<id>.jsonl`,
/// Antigravity in `~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl`; each is
/// named by the conversation id the daemon reports (`SessionInfo.conversationId`). PI keeps none AiTerm reads.
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
        case .agy:
            let file = home.appendingPathComponent(".gemini/antigravity-cli/brain")
                .appendingPathComponent(conversation).appendingPathComponent(".system_generated/logs/transcript.jsonl")
            return fileManager.fileExists(atPath: file.path) ? file : nil
        case .pi:
            return nil
        }
    }

    /// The newest reply in the file's last `tailBytes`, read from the end.
    struct Reply: Sendable {
        let text: String; let identity: Int; let fingerprint: String
        init(text: String, identity: Int, fingerprint: String = "") { self.text = text; self.identity = identity; self.fingerprint = fingerprint }
    }

    static func lastMessage(in file: URL, agent: AgentKind) -> String? { lastReply(in: file, agent: agent)?.text }

    /// The full assistant record identifies the reply even when its text repeats in a later turn.
    static func lastReply(in file: URL, agent: AgentKind) -> Reply? { readReply(in: file, agent: agent)?.reply }

    /// What reading a file's tail found: its newest reply, nil when it has none.
    struct TailRead: Sendable { let reply: Reply? }

    /// The file's tail as read (`TailRead`); nil when the file could not be read at all.
    static func readReply(in file: URL, agent: AgentKind) -> TailRead? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        // A read that starts mid-file starts mid-line.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        let decoder = JSONDecoder()
        for line in lines.reversed() {
            guard let record = try? decoder.decode(JSONValue.self, from: Data(line.utf8)),
                  let text = reply(record, agent: agent), !text.isEmpty else { continue }
            return TailRead(reply: Reply(text: text, identity: line.hashValue, fingerprint: SHA256.hash(data: Data(line.utf8)).map { String(format: "%02x", $0) }.joined()))
        }
        return TailRead(reply: nil)
    }

    /// The reply a record of `agent`'s carries, if it is one.
    static func reply(_ record: JSONValue, agent: AgentKind) -> String? {
        switch agent {
        case .claude: claudeReply(record)
        case .codex: codexReply(record)
        case .agy: agyReply(record)
        case .pi: nil
        }
    }

    /// Antigravity's model step: a `PLANNER_RESPONSE` with text. One that only calls tools says nothing.
    static func agyReply(_ record: JSONValue) -> String? {
        guard record["type"]?.stringValue == "PLANNER_RESPONSE", record["source"]?.stringValue == "MODEL" else { return nil }
        return record["content"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
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

/// Finds each worker conversation's transcript for `SignalWorkerIO`'s turn reading and `read_task`.
/// A lookup lists Claude's project folders or walks Codex's sessions under `home` and the configured
/// Claude folder. A found file is reused while it exists; its newest reply is kept until its stamp changes.
/// Blocking: read off the main actor.
final class TranscriptLocator: Sendable {
    let home: URL
    let claudeConfig: ClaudeConfig
    private let found = Mutex<[String: URL]>([:])
    /// The file as last read, a link followed to the file it names: which file it is (its device and file number), when
    /// it was written and how long it was.
    private struct Stamp: Equatable { let device: Int, file: UInt64, modified: Date, size: UInt64 }
    /// Each conversation's newest reply as last read, with its file's stamp then, by conversation id and agent.
    private struct Kept { let stamp: Stamp, reply: WorkerTranscript.Reply? }
    private let replies = Mutex<[String: Kept]>([:])

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
    func lastMessage(agent: AgentKind, conversation: String) -> String? { lastReply(agent: agent, conversation: conversation)?.text }

    /// The conversation's newest reply, its tail read again only when the file's stamp changes.
    /// A link is followed so the file read is the file stamped. An unreadable file keeps nothing,
    /// so the next ask reads it again.
    func lastReply(agent: AgentKind, conversation: String) -> WorkerTranscript.Reply? {
        guard let found = file(agent: agent, conversation: conversation) else { return nil }
        let file = found.resolvingSymlinksInPath()
        let key = agent.rawValue + "/" + conversation, stamp = Self.stamp(of: file)
        if let stamp, let kept = replies.withLock({ $0[key] }), kept.stamp == stamp { return kept.reply }
        // Stamped before the read: a write in between is read again next time.
        let read = WorkerTranscript.readReply(in: file, agent: agent)
        replies.withLock { replies in
            replies[key] = read.flatMap { read in stamp.map { Kept(stamp: $0, reply: read.reply) } }
        }
        return read?.reply
    }

    private static func stamp(of file: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let device = attributes[.systemNumber] as? NSNumber, let number = attributes[.systemFileNumber] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? NSNumber else { return nil }
        return Stamp(device: device.intValue, file: number.uint64Value, modified: modified, size: size.uint64Value)
    }
}
