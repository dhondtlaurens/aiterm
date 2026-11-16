import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// Evaluates each scenario three times on the current Operator brief through `claude -p`,
/// against the stub MCP server (`daemon/tools/operator_stub.py`). Calls and chat are graded.
/// Uses quota, so it is enabled only with `AITERM_LIVE_OPERATOR=1`.
///
/// Uses the Operator's model and reasoning from Settings > Operator. `AITERM_EVAL_MODEL` overrides
/// the model, with no reasoning flag. Each evaluation's brief, replies, calls and chat are kept
/// in `AITERM_EVAL_OUT`, or a folder in the temporary directory, whose path it prints.
///
/// Prints a table by scenario and reports each failure. A miss is a finding about the brief:
/// change the brief, not the scenario.
///
/// Each invocation passes `--max-turns` and a timeout to bound the evaluation,
/// `--no-session-persistence` to leave no conversations behind, and `disableAllHooks`
/// so AiTerm's hooks do not report the evaluation to the app that may be open.
enum OperatorEvalRunner {
    static let runsPerBrief = 3, maxTurns = 12, atOnce = 3
    static let runTimeout: TimeInterval = 600
    /// The app's defaults domain, its bundle identifier: where Settings › Operator keeps the profile.
    static let appDefaults = "com.laurensdhondt.aiterm"

    struct Brief: Sendable { var name: String; var brief: URL; var tools: URL }
    struct Job: Sendable { var scenario: EvalScenario; var brief: Brief; var number: Int; var stream = false }
    struct Outcome: Sendable { var scenario: String; var brief: String; var number: Int; var failures: [String] }

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var daemon: URL { root.appendingPathComponent("daemon") }
    static var python: URL { daemon.appendingPathComponent(".venv/bin/python") }

    static func run(_ job: Job, claude: String, words: [String], in out: URL) -> Outcome {
        let folder = out.appendingPathComponent(job.scenario.name).appendingPathComponent("\(job.brief.name)-\(job.number)")
        let outcome = { (failures: [String]) in
            try? Data((failures.isEmpty ? "pass\n" : failures.joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent("grade.txt"))
            return Outcome(scenario: job.scenario.name, brief: job.brief.name, number: job.number, failures: failures)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let replies = folder.appendingPathComponent("replies.json"), log = folder.appendingPathComponent("calls.jsonl")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(job.scenario.replies).write(to: replies)
            let (stub, port) = try startStub(tools: job.brief.tools, replies: replies, log: log, in: folder)
            defer { stub.terminate(); stub.waitUntilExit() }
            let mcp = folder.appendingPathComponent(OperatorCommand.mcpFile)
            try Data(OperatorCommand.mcpConfig(hookPort: port, token: OperatorCommand.makeToken()).utf8).write(to: mcp)
            let arguments = words + ["-p", "--append-system-prompt-file", job.brief.brief.path, "--tools", "Read,Grep,Glob",
                                     "--mcp-config", mcp.path, "--allowedTools", "mcp__aiterm__*", "--max-turns", String(maxTurns),
                                     "--output-format", job.stream ? "stream-json" : "json", "--no-session-persistence",
                                     "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config"] + (job.stream ? ["--verbose"] : []) + [job.scenario.firstMessage]
            let workingDirectory = try ScratchFolder.make("aiterm-operator-eval-work-")
            defer { try? FileManager.default.removeItem(at: workingDirectory) }
            let result = try ProcessRunner.run(URL(fileURLWithPath: claude), arguments, in: workingDirectory, timeout: runTimeout)
            try Data(result.stdout.utf8).write(to: folder.appendingPathComponent("claude.json"))
            try Data(result.stderr.utf8).write(to: folder.appendingPathComponent("claude.stderr"))
            let parsed = output(result.stdout, stream: job.stream), answer = parsed.answer
            if job.stream {
                try Data(result.stdout.utf8).write(to: folder.appendingPathComponent("claude.jsonl"))
                if let answer { try encoder.encode(answer).write(to: folder.appendingPathComponent("claude.json")) }
            }
            let transcript = EvalTranscript(calls: calls(in: log), reply: parsed.chat)
            try Data(transcript.reply.utf8).write(to: folder.appendingPathComponent("reply.md"))
            var failures = job.scenario.check(transcript)
            if result.timedOut { failures.insert("the run timed out after \(Int(runTimeout)) s", at: 0) }
            else if answer?["subtype"]?.stringValue == "error_max_turns" { failures.insert("the run reached \(maxTurns) turns", at: 0) }
            else if answer == nil { failures.insert("claude answered no JSON (exit \(result.status))", at: 0) }
            else if answer?["is_error"]?.boolValue == true { failures.insert("model error: " + (answer?["result"]?.stringValue ?? "unknown error"), at: 0) }
            return outcome(failures)
        } catch {
            return outcome(["the run couldn't start: \(error)"])
        }
    }

    /// stream-json includes plain chat written before a tool. The final result alone drops it.
    static func output(_ text: String, stream: Bool) -> (answer: JSONValue?, chat: String) {
        if !stream {
            let answer = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            return (answer, answer?["result"]?.stringValue ?? "")
        }
        let records = text.split(whereSeparator: \.isNewline).compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let answer = records.last { $0["type"] == "result" }
        var words: [String] = []
        for record in records where record["type"] == "assistant" {
            let content = record["message"]?["content"]?.arrayValue ?? []
            for block in content where block["type"] == "text" {
                if let text = block["text"]?.stringValue { words.append(text) }
            }
        }
        let chat = words.joined(separator: "\n")
        return (answer, chat.isEmpty ? answer?["result"]?.stringValue ?? "" : chat)
    }

    /// The stub MCP server, from the daemon's venv, and the port its first line names.
    static func startStub(tools: URL, replies: URL, log: URL, in folder: URL) throws -> (Process, Int) {
        let stub = Process()
        stub.executableURL = python
        stub.arguments = ["-m", "tools.operator_stub", "--tools", tools.path, "--replies", replies.path, "--log", log.path]
        stub.currentDirectoryURL = daemon
        stub.environment = ProcessRunner.inheritedEnvironment.filter { $0.key != "PYTHONPATH" }
        stub.standardInput = FileHandle.nullDevice
        let output = Pipe()
        stub.standardOutput = output
        FileManager.default.createFile(atPath: folder.appendingPathComponent("stub.stderr").path, contents: nil)
        stub.standardError = try FileHandle(forWritingTo: folder.appendingPathComponent("stub.stderr"))
        try stub.run()
        var line = Data()
        while !line.contains(UInt8(ascii: "\n")) {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            line.append(chunk)
        }
        let words = String(decoding: line, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, words[0] == "port", let port = Int(words[1]) else {
            stub.terminate()
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "the stub named no port; see stub.stderr"])
        }
        return (stub, port)
    }

    /// The calls the stub logged, in order.
    static func calls(in log: URL) -> [(tool: String, arguments: JSONValue)] {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let call = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)), let tool = call["tool"]?.stringValue
            else { return nil }
            return (tool: tool, arguments: call["arguments"] ?? [:])
        }
    }

    /// The tools as the working daemon serves them now.
    static func dumpTools(to url: URL) throws {
        let result = try ProcessRunner.run(python, ["-c", "import json; from aitermd.operator_mcp import TOOLS; print(json.dumps(list(TOOLS)))"],
                                           environment: ProcessRunner.inheritedEnvironment.filter { $0.key != "PYTHONPATH" },
                                           in: daemon, timeout: 60)
        guard result.status == 0, !result.stdout.isEmpty else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "the daemon's tools couldn't be read: \(result.stderr)"])
        }
        try Data(result.stdout.utf8).write(to: url)
    }

    /// `AITERM_EVAL_MODEL`, else the Operator's model and reasoning from Settings › Operator, as the app reads them.
    static func model(_ environment: [String: String]) -> (model: String, effort: String?) {
        if let model = environment["AITERM_EVAL_MODEL"], !model.isEmpty { return (model, nil) }
        let defaults = UserDefaults(suiteName: appDefaults) ?? .standard
        let profile = OperatorProfileStore.load(defaults, claudeDefault: OperatorProfileStore.claudeDefault(models: [], defaults: defaults))
        return (profile.model, profile.reasoning)
    }

    /// Scenario, then how many runs passed on each brief.

}
