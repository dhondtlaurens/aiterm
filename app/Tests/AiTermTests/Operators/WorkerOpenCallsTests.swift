import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm

/// The tool calls a worker started and has no result for yet, read from its conversation file (`WorkerTranscript.openCalls`):
/// a call that runs writes nothing until it returns, so its worker is at work though its file says nothing.
@Suite struct WorkerOpenCallsTests {
    let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("aiterm-open-calls-\(UUID().uuidString)")
    let now = Date(timeIntervalSince1970: 1_000_000)

    private func cleanUp() { try? FileManager.default.removeItem(at: home) }

    /// `lines` as the file's whole content, each ended by a newline unless `partial` leaves the last one cut off.
    @discardableResult
    private func write(_ lines: [String], to name: String = "conv.jsonl", partial: Bool = false) throws -> URL {
        let url = home.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + (partial ? "" : "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func stamp(_ seconds: TimeInterval) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.string(from: now.addingTimeInterval(seconds))
    }

    private func claudeUse(_ id: String, at seconds: TimeInterval = 0, sidechain: Bool = false) -> String {
        #"{"type":"assistant","isSidechain":\#(sidechain),"timestamp":"\#(stamp(seconds))","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"Bash","input":{"command":"scripts/test.sh"}}]}}"#
    }

    private func claudeResult(_ id: String, at seconds: TimeInterval = 0, padding: Int = 0) -> String {
        #"{"type":"user","isSidechain":false,"timestamp":"\#(stamp(seconds))","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"ok\#(String(repeating: "r", count: padding))"}]}}"#
    }

    private func filler(_ size: Int) -> String {
        #"{"type":"mode","mode":"\#(String(repeating: "f", count: size))"}"#
    }

    private func codex(_ type: String, _ payload: String, at seconds: TimeInterval = 0) -> String {
        #"{"timestamp":"\#(stamp(seconds))","type":"\#(type)","payload":{\#(payload)}}"#
    }

    private func open(_ file: URL, _ agent: AgentKind = .claude, after earlier: WorkerTranscript.OpenCalls? = nil,
                      window: Int = WorkerTranscript.callWindowBytes) throws -> WorkerTranscript.OpenCalls {
        try #require(WorkerTranscript.openCalls(in: file, agent: agent, after: earlier, now: now.addingTimeInterval(600), windowBytes: window))
    }

    /// The case seen: a Bash call whose result came four minutes on. Until it comes the call is open, from its start; a
    /// subagent's own call (`isSidechain`) is not its parent's.
    @Test func aClaudeToolUseIsOpenUntilItsResult() throws {
        defer { cleanUp() }
        let file = try write([claudeUse("toolu_a", at: 0), claudeResult("toolu_a", at: 239), claudeUse("toolu_b", at: 253),
                              claudeUse("toolu_side", at: 260, sidechain: true)])
        let calls = try open(file)
        #expect(calls.started == ["toolu_b": now.addingTimeInterval(253)])
        #expect(calls.since == now.addingTimeInterval(253))
        try write([claudeUse("toolu_a", at: 0), claudeResult("toolu_a", at: 239), claudeUse("toolu_b", at: 253), claudeResult("toolu_b", at: 825)])
        #expect(try open(file).started.isEmpty)
    }

    /// Codex's function and custom tool calls, each closed by its output with the same call id, and every call of a turn
    /// that ended or was interrupted.
    @Test func aCodexCallIsOpenUntilItsOutputOrItsTurnsEnd() throws {
        defer { cleanUp() }
        let lines = [
            codex("response_item", #""type":"custom_tool_call","call_id":"call_x","name":"exec","status":"completed""#, at: 0),
            codex("response_item", #""type":"custom_tool_call_output","call_id":"call_x","output":[]"#, at: 1),
            codex("response_item", #""type":"function_call","call_id":"call_sleep","name":"sleep","arguments":"{}""#, at: 2),
        ]
        let file = try write(lines, to: "rollout.jsonl")
        #expect(try open(file, .codex).started == ["call_sleep": now.addingTimeInterval(2)])
        try write(lines + [codex("response_item", #""type":"function_call_output","call_id":"call_sleep","output":"done""#, at: 501)],
                  to: "rollout.jsonl")
        #expect(try open(file, .codex).started.isEmpty)
        try write(lines + [codex("event_msg", #""type":"turn_aborted","reason":"interrupted""#, at: 30)], to: "rollout.jsonl")
        #expect(try open(file, .codex).started.isEmpty, "an interrupted turn's call runs no more")
    }

    /// Read again, the file is read on from where the last read stopped: a call whose start has since left the window's
    /// reach is still open, and its result, once written, closes it.
    @Test func aCallStaysOpenAcrossReadsThoughItsStartLeavesTheWindow() throws {
        defer { cleanUp() }
        let window = 2048
        var lines = [filler(3000), claudeUse("toolu_b", at: 0)]
        let file = try write(lines)
        var calls = try open(file, window: window)
        #expect(Set(calls.started.keys) == ["toolu_b"])
        for _ in 0..<3 {
            lines.append(filler(1200))
            try write(lines)
            calls = try open(file, after: calls, window: window)
        }
        #expect(Set(calls.started.keys) == ["toolu_b"], "its start is more than a window back, and it is still open")
        lines.append(claudeResult("toolu_b", at: 300))
        try write(lines)
        #expect(try open(file, after: calls, window: window).started.isEmpty)
    }

    /// A first read of a long file starts mid-line: the cut line is dropped, and a result whose call lies before the window
    /// invents no open call, nor does a call cut in half.
    @Test func aWindowThatStartsMidLineInventsNoCall() throws {
        defer { cleanUp() }
        let window = 2048
        let cutResult = try write([claudeUse("toolu_a", at: 0), claudeResult("toolu_a", at: 5, padding: 1500), filler(1000)])
        #expect(try open(cutResult, window: window).started.isEmpty)
        let cutUse = try write([filler(3000), claudeUse("toolu_c", at: 0) + String(repeating: " ", count: 2000),
                                claudeResult("toolu_c", at: 5)], to: "cut-use.jsonl")
        #expect(try open(cutUse, window: window).started.isEmpty)
    }

    /// A last line still being written is not read: its call stays as it was until the line is whole.
    @Test func aLineStillBeingWrittenIsReadOnceWhole() throws {
        defer { cleanUp() }
        let use = claudeUse("toolu_b", at: 0), result = claudeResult("toolu_b", at: 60)
        let file = try write([use, String(result.prefix(40))], partial: true)
        let calls = try open(file)
        #expect(Set(calls.started.keys) == ["toolu_b"])
        try write([use, result])
        #expect(try open(file, after: calls).started.isEmpty)
    }

    /// A call open past `openCallMinutes` is forgotten: a worker that died mid-call leaves nothing that holds it at work.
    @Test func aCallOpenPastTheCapIsForgotten() throws {
        defer { cleanUp() }
        let file = try write([claudeUse("toolu_old", at: -Double(OperatorTiming.openCallMinutes) * 60), claudeUse("toolu_new", at: 0)])
        #expect(Set(try open(file).started.keys) == ["toolu_new"])
    }
}
