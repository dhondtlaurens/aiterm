import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

/// `read_task(lastMessage)` reads the worker's own conversation file, never its screen.
@Suite struct WorkerTranscriptTests {
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aiterm-transcripts-\(UUID().uuidString)")

    private func cleanUp() { try? FileManager.default.removeItem(at: home) }

    @discardableResult
    private func write(_ lines: [String], to path: String) throws -> URL {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func claudesLastReplyIsItsLastAssistantTextNotItsToolCall() throws {
        defer { cleanUp() }
        try write([
            #"{"type":"user","message":{"role":"user","content":"go"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Should I also migrate the table?"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#,
        ], to: ".claude/projects/-Users-x-shop--worktrees-pluto-1/0d9c-conv.jsonl")
        #expect(WorkerTranscript.lastMessage(agent: .claude, conversation: "0d9c-conv", home: home) == "Should I also migrate the table?")
    }

    @Test func codexsLastReplyIsItsLastAgentMessage() throws {
        defer { cleanUp() }
        try write([
            #"{"type":"session_meta","payload":{"id":"019a-thread"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"First."}]}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"Tests pass. Commit 4f2a91c."}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#,
        ], to: ".codex/sessions/2026/10/16/rollout-2026-10-16T09-00-00-019a-thread.jsonl")
        #expect(WorkerTranscript.lastMessage(agent: .codex, conversation: "019a-thread", home: home) == "Tests pass. Commit 4f2a91c.")
    }

    @Test func onlyTheEndOfALongTranscriptIsRead() throws {
        defer { cleanUp() }
        let filler = String(repeating: "x", count: 1000)
        let lines = (0..<700).map { #"{"type":"user","message":{"role":"user","content":"\#(filler)\#($0)"}}"# }
            + [#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}"#]
        let file = try write(lines, to: ".claude/projects/p/long.jsonl")
        #expect(WorkerTranscript.lastMessage(in: file, agent: .claude) == "Done.")
    }

    private let assistantLine = { (text: String) in
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }
    private func userLine(_ size: Int) -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(String(repeating: "u", count: size))"}}"#
    }

    @Test func aReplyBeforeTheTailWindowIsNotRead() throws {
        defer { cleanUp() }
        let lines = [assistantLine("Early.")] + (0..<700).map { _ in userLine(1000) }
        let file = try write(lines, to: ".claude/projects/p/early.jsonl")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        #expect(size > WorkerTranscript.tailBytes)
        #expect(WorkerTranscript.lastMessage(in: file, agent: .claude) == nil)
    }

    @Test func aTailThatStartsMidRecordDropsThePartialLineAndStillFindsTheReply() throws {
        defer { cleanUp() }
        let straddler = assistantLine("Partial." + String(repeating: "p", count: 2000))
        let reply = assistantLine("Whole.")
        var after = [String]()
        var afterBytes = reply.utf8.count + 1
        while afterBytes < WorkerTranscript.tailBytes - 1000 {
            let line = userLine(60)
            after.append(line)
            afterBytes += line.utf8.count + 1
        }
        // The window starts inside `straddler`: it reaches back less than its length from its end.
        #expect(afterBytes < WorkerTranscript.tailBytes && afterBytes + straddler.utf8.count > WorkerTranscript.tailBytes)
        let file = try write((0..<20).map { _ in userLine(1000) } + [straddler] + after + [reply], to: ".claude/projects/p/straddle.jsonl")
        #expect(WorkerTranscript.lastMessage(in: file, agent: .claude) == "Whole.")
        // The straddling record cut off at the boundary is dropped, not read: with no reply after it, nothing is found.
        let alone = try write((0..<20).map { _ in userLine(1000) } + [straddler] + after, to: ".claude/projects/p/alone.jsonl")
        #expect(WorkerTranscript.lastMessage(in: alone, agent: .claude) == nil)
    }

    @Test func aConversationIdThatIsAPathFindsNothing() {
        defer { cleanUp() }
        #expect(WorkerTranscript.file(agent: .claude, conversation: "../../etc/passwd", home: home) == nil)
        #expect(WorkerTranscript.lastMessage(agent: .codex, conversation: "missing", home: home) == nil)
    }
}
