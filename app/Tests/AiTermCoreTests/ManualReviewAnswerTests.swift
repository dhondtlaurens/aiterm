import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct ManualReviewAnswerTests {
    // A denied tool can be followed by a successful final result on agy 1.5.18.
    @Test func denialWinsOverAnAnswer() throws {
        let folder = try ScratchFolder.make("review-denial-")
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("events")
        try Data("""
        {"event":"step_update","step_update":{"state":"ERROR","tool_info":{"name":"read_file","error":{"type":"TOOL_ERROR","message":"Permission denied for read_file"}}}}
        {"event":"result","result":{"status":"SUCCESS","response":"Looks fine."}}
        """.utf8).write(to: log)
        #expect(throws: ManualReviewError.self) { try AgentKind.agy.manualReviewAnswer(events: log, answerFile: nil) }
    }
}

extension ManualReviewAnswerTests {
    @Test func allEventsIncludingALateDenialAreRead() async throws {
        let folder = try ScratchFolder.make("review-stream-")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("events")
        let progress = "{\"event\":\"progress\",\"text\":\"" + String(repeating: "x", count: 4096) + "\"}\n"
        let prefix = String(repeating: progress, count: 1100)
        let success = #"{"event":"result","result":{"status":"SUCCESS","response":"No findings."}}"#
        let refusal = #"{"step_update":{"state":"ERROR","tool_info":{"name":"read_file","error":{"message":"Permission denied for read_file"}}}}"#
        let input = folder.appendingPathComponent("input")
        for (tail, overflow) in [(success, false), (refusal + "\n" + success, false), (success, true)] {
            let data = Data((prefix + tail).utf8)
            try data.write(to: input)
            try Data().write(to: file)
            let capture = try FileHandle(forWritingTo: file)
            defer { try? capture.close() }
            let budget = data.count - (overflow ? 1 : 0)
            let output = try await AgentProcess.run("/bin/cat", [input.path], environment: [:], in: folder.path,
                                                    timeout: .seconds(30), outputLimit: budget, capture: capture)
            #expect(output.status == 0 && output.stdoutTruncated == overflow)
            #expect(try Data(contentsOf: file) == data.prefix(budget))
            if tail == success && !overflow {
                #expect(try AgentKind.agy.manualReviewAnswer(events: file, answerFile: nil) == "No findings.")
            } else {
                #expect(throws: (any Error).self) { try AgentKind.agy.manualReviewAnswer(events: file, answerFile: nil) }
            }
        }
    }

    @Test func capturedVendorFailuresAndOrdinaryMisses() throws {
        let folder = try ScratchFolder.make("review-answers-")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("events")
        // Shapes from print/exec captures, with synthetic paths and answer text.
        let terminal = #"{"type":"agent_end","willRetry":false,"messages":[{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"No findings."}]}]}"#
        let miss = #"{"type":"tool_execution_end","isError":true,"result":{"content":[{"type":"text","text":"ENOENT: no such file or directory"}]}}"#
        try Data((miss + "\n" + terminal).utf8).write(to: file)
        #expect(try AgentKind.pi.manualReviewAnswer(events: file, answerFile: nil) == "No findings.")
        for (vendor, log): (AgentKind, String) in [
            (.pi, miss.replacingOccurrences(of: "ENOENT: no such file or directory", with: "EACCES: permission denied") + "\n" + terminal),
            (.claude, #"{"type":"result","is_error":false,"permission_denials":[{"tool_name":"Read"}],"result":"Done"}"#),
            (.claude, #"{"type":"result","is_error":false,"permission_denials":[],"result":" "}"#),
            (.codex, #"{"type":"item.completed","item":{"type":"command_execution","exit_code":1,"aggregated_output":"touch: marker: Operation not permitted"}}"#),
            (.agy, #"{"event":"result","result":{"status":"ERROR","response":"Looks fine"}}"#),
            (.agy, ""), (.agy, "{")
        ] {
            try Data(log.utf8).write(to: file)
            #expect(throws: (any Error).self) { try vendor.manualReviewAnswer(events: file, answerFile: nil) }
        }
    }
}
