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

    /// The tool calls a conversation started and has no result for yet, as far as its file was read: a call that runs
    /// writes nothing until it returns, so its worker is at work though its file says nothing (`WorkerQuietWatch`).
    struct OpenCalls: Equatable, Sendable {
        /// Each open call's id (Claude's `tool_use` id, Codex's `call_id`), and when it started.
        var started: [String: Date] = [:]
        /// Where the next read goes on from: the end of the last whole line read.
        var readTo: UInt64 = 0

        /// When the newest open call started; nil with none open.
        var since: Date? { started.values.max() }
    }

    /// How much of a conversation's end a first read looks through for its open calls, and how much growth a later one
    /// reads on through before it starts afresh. A call that runs writes nothing, so its start is near the file's end.
    static let callWindowBytes = 4 * 1024 * 1024

    /// The conversation's open calls, read on from `earlier` (the last read of this file) when the file grew by no more than
    /// `windowBytes` since, else afresh from its last `windowBytes`. Only whole lines are read: one still being written is
    /// read once it is whole. A fresh read that starts mid-file drops the line it cuts, and a result whose call lies before
    /// the window closes nothing, so no call is invented. Claude: a main-chain `tool_use` with no `tool_result` naming its id
    /// since. Codex: a `function_call` or `custom_tool_call` with no output naming its `call_id`, in a turn that has not ended
    /// or been interrupted. A call open for `OperatorTiming.openCallMinutes` by `now` is forgotten. Nil when the file can't
    /// be read.
    static func openCalls(in file: URL, agent: AgentKind, after earlier: OpenCalls?, now: Date,
                          windowBytes: Int = callWindowBytes) -> OpenCalls? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0, window = UInt64(windowBytes)
        var calls = OpenCalls(), start: UInt64, fresh = true
        if let earlier, earlier.readTo <= size, size - earlier.readTo <= window {
            calls = earlier
            start = earlier.readTo
            fresh = false
        } else {
            start = size > window ? size - window : 0
        }
        calls.readTo = start
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd(),
              let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return calls.pruned(now: now) }
        calls.readTo = start + UInt64(end - data.startIndex + 1)
        var lines = data[data.startIndex..<end].split(separator: UInt8(ascii: "\n"))
        // A fresh read that starts mid-file starts mid-line.
        if fresh, start > 0, !lines.isEmpty { lines.removeFirst() }
        let decoder = JSONDecoder()
        for line in lines {
            guard let record = try? decoder.decode(JSONValue.self, from: Data(line)) else { continue }
            if agent == .codex { calls.codex(record, now: now) } else { calls.claude(record, now: now) }
        }
        return calls.pruned(now: now)
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

extension WorkerTranscript.OpenCalls {
    /// When a record was written, by its own `timestamp`; `now` for one that has none.
    private static func written(_ record: JSONValue, now: Date) -> Date {
        guard let text = record["timestamp"]?.stringValue else { return now }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: text) { return date }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: text) ?? now
    }

    /// A Claude record: a main-chain assistant record's `tool_use` blocks open a call, a `tool_result` closes the one it names.
    mutating func claude(_ record: JSONValue, now: Date) {
        guard let content = record["message"]?["content"]?.arrayValue else { return }
        let assistant = record["type"]?.stringValue == "assistant" && record["isSidechain"]?.boolValue != true
        for block in content {
            switch block["type"]?.stringValue {
            case "tool_use" where assistant:
                if let id = block["id"]?.stringValue { started[id] = Self.written(record, now: now) }
            case "tool_result":
                if let id = block["tool_use_id"]?.stringValue { started[id] = nil }
            default: break
            }
        }
    }

    /// A Codex record: a call opens one, its output closes it, and its turn's end or interruption closes every one.
    mutating func codex(_ record: JSONValue, now: Date) {
        let payload = record["payload"], type = payload?["type"]?.stringValue ?? ""
        switch record["type"]?.stringValue {
        case "response_item":
            guard let id = payload?["call_id"]?.stringValue else { return }
            if ["function_call", "custom_tool_call"].contains(type) { started[id] = Self.written(record, now: now) }
            else if type.hasSuffix("_output") { started[id] = nil }
        case "event_msg" where ["task_complete", "turn_aborted"].contains(type):
            started = [:]
        default: break
        }
    }

    /// Without the calls open for `OperatorTiming.openCallMinutes` by `now`.
    func pruned(now: Date) -> Self {
        var calls = self
        calls.started = started.filter { StallWatch.isCallRunning(since: $0.value, now: now) }
        return calls
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
