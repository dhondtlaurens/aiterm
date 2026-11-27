import Foundation
import Darwin

private typealias Event = [String: Any]

/// Read one vendor record at a time. Both the capture file and an individual record have
/// bounds. A malformed or incomplete stream cannot authenticate a final answer.
private func records(in url: URL, _ visit: (Event) throws -> Void) throws {
    guard let file = fopen(url.path, "r") else { throw ManualReviewError("Cannot open the reviewer event log.") }
    defer { fclose(file) }
    var line: UnsafeMutablePointer<CChar>?, capacity = 0
    defer { free(line) }
    while true {
        let length = getline(&line, &capacity, file)
        if length < 0 { break }
        guard length <= 128 << 20, let line,
              let json = try JSONSerialization.jsonObject(with: Data(bytes: line, count: length)) as? Event else {
            throw ManualReviewError("Invalid reviewer event.")
        }
        try visit(json)
    }
    if ferror(file) != 0 { throw ManualReviewError("Could not read the complete reviewer event log.") }
}

private func permissionFailure(_ message: String) -> Bool {
    ["permission denied", "operation not permitted", "read-only file system", "denied by", "sandboxdenied",
     "sandbox(denied", "eacces:", "eperm:"].contains { message.localizedCaseInsensitiveContains($0) }
}

private func denied(_ reason: String) -> ManualReviewError {
    ManualReviewError("Reviewer action denied. " + String(reason.prefix(350)))
}

extension AgentKind {
    public func manualReviewAnswer(events: URL, answerFile: String?) throws -> String {
        var answer: String?, complete = false, codexThread: String?
        try records(in: events) { event in
            switch self {
            case .claude:
                if let refusals = event["permission_denials"] as? [Event], let first = refusals.first {
                    throw denied(first["tool_name"] as? String ?? "Claude tool")
                }
                guard event["type"] as? String == "result", event["is_error"] as? Bool == false else {
                    throw ManualReviewError("Claude reported an unsuccessful result.")
                }
                answer = try decodedAnswer(event)
                complete = true
            case .agy:
                if let step = event["step_update"] as? Event, let tool = step["tool_info"] as? Event {
                    if let error = tool["error"] as? Event, let message = error["message"] as? String,
                       permissionFailure(message) { throw denied(message) }
                    if let name = tool["name"] as? String, name != "read_file" { throw denied(name) }
                }
                if event["event"] as? String == "result", let result = event["result"] as? Event {
                    if let actions = result["denied_actions"] as? [Event], !actions.isEmpty { throw denied("Antigravity tool") }
                    guard result["status"] as? String == "SUCCESS" else { throw ManualReviewError("Antigravity reported an unsuccessful result.") }
                    answer = try decodedAnswer(result)
                    complete = true
                }
            case .codex:
                switch event["type"] as? String {
                case "thread.started": codexThread = event["thread_id"] as? String
                case "turn.completed": complete = true
                case "turn.failed", "error": throw ManualReviewError("Codex reported a failed review.")
                case "item.completed":
                    if let item = event["item"] as? Event {
                        if item["type"] as? String == "error" { throw ManualReviewError(item["message"] as? String ?? "Codex tool failed.") }
                        if let code = item["exit_code"] as? Int, code != 0, let text = item["aggregated_output"] as? String,
                           permissionFailure(text) { throw denied(text) }
                    }
                default: break
                }
            case .pi:
                if event["type"] as? String == "tool_execution_end", event["isError"] as? Bool == true,
                   let result = event["result"] as? Event {
                    let text = Self.messageText(result)
                    if permissionFailure(text) { throw denied(text) }
                }
                if event["type"] as? String == "agent_end", event["willRetry"] as? Bool != true {
                    let last = (event["messages"] as? [Event])?.last
                    guard let last, last["role"] as? String == "assistant", last["stopReason"] as? String == "stop" else {
                        throw ManualReviewError("PI reported an unsuccessful review.")
                    }
                    complete = true
                    answer = harness.headlessAnswer(Self.messageText(last), nil)
                }
            }
        }
        if self == .codex, complete {
            guard let codexThread, UUID(uuidString: codexThread) != nil else { throw ManualReviewError("Missing Codex review session.") }
            try Self.checkCodexToolResults(thread: codexThread)
            answer = harness.headlessAnswer("", answerFile)
        }
        guard complete, let result = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else {
            throw ManualReviewError(displayName + " returned no complete answer.")
        }
        return result
    }

    private static func messageText(_ message: Event) -> String {
        (message["content"] as? [Event])?.compactMap { piece in
            piece["type"] as? String == "text" ? piece["text"] as? String : nil
        }.joined(separator: "\n") ?? ""
    }

    private func decodedAnswer(_ record: Event) throws -> String? {
        harness.headlessAnswer(String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self), nil)
    }

    /// Codex 0.171 can omit Code Mode's nested shell results from exec --json. Its own
    /// rollout contains the structured exit code and OS error, even when the final answer says success.
    private static func checkCodexToolResults(thread: String) throws {
        let fm = FileManager.default
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let sessions = home.appendingPathComponent("sessions")
        let walk = fm.enumerator(at: sessions, includingPropertiesForKeys: nil)
        while let file = walk?.nextObject() as? URL {
            guard file.lastPathComponent.hasPrefix("rollout-"), file.lastPathComponent.hasSuffix("-" + thread + ".jsonl") else { continue }
            try records(in: file) { record in
                guard record["type"] as? String == "response_item", let item = record["payload"] as? Event else { return }
                if item["type"] as? String == "function_call_output", let message = item["output"] as? String,
                   message.hasPrefix("exec_command failed:"), permissionFailure(message) { throw denied(message) }
                guard item["type"] as? String == "custom_tool_call_output", let parts = item["output"] as? [Event] else { return }
                for part in parts {
                    guard let text = part["text"] as? String, text.first == "{",
                          let execution = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? Event,
                          let code = execution["exit_code"] as? Int, code != 0, let output = execution["output"] as? String,
                          permissionFailure(output) else { continue }
                    throw denied(output)
                }
            }
            return
        }
        throw ManualReviewError("Could not verify the tool results for this Codex review.")
    }
}
