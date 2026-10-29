import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// The Operator's brief, live (spec §5): each scenario of `OperatorEvalGrading` run through `claude -p` three times on
/// each brief, the current structured baseline captured at f152f6e9 and the brief now
/// (`OperatorCommand.brief`, with the daemon's tools now), against the stub MCP server
/// (`daemon/tools/operator_stub.py`), and graded on the calls and the final reply. Uses quota, so it runs only with
/// `AITERM_LIVE_OPERATOR=1`.
///
/// It runs on the Operator's model from Settings › Operator, at its reasoning, as the person's broadcasts do;
/// `AITERM_EVAL_MODEL` overrides the model, with no reasoning flag. Each run's brief, replies, calls and reply are kept
/// in `AITERM_EVAL_OUT`, or a folder in the temporary directory, whose path it prints.
///
/// It prints a table, scenario by scenario, and fails for each scenario the new brief misses on any of its three runs; the
/// baseline is reported separately. A miss is a finding about the brief, as in `FixLiveTests`:
/// change the brief, not the scenario.
///
/// Beyond the Operator's own command, each run passes `--max-turns` and a timeout, so a run that loops can't hang the
/// suite; `--no-session-persistence`, so the runs leave no conversations behind; and `disableAllHooks`, so AiTerm's own
/// hooks don't report every run to the AiTerm that may be open.
@Suite(.blocking, .enabled(if: ProcessInfo.processInfo.environment["AITERM_LIVE_OPERATOR"] == "1"))
struct OperatorEvalTests {
    static let runsPerBrief = 3, maxTurns = 12, atOnce = 3
    static let runTimeout: TimeInterval = 600
    /// The app's defaults domain, its bundle identifier: where Settings › Operator keeps the profile.
    static let appDefaults = "com.laurensdhondt.aiterm"

    struct Brief: Sendable { var name: String; var brief: URL; var tools: URL }
    struct Job: Sendable { var scenario: EvalScenario; var brief: Brief; var number: Int }
    struct Outcome: Sendable { var scenario: String; var brief: String; var number: Int; var failures: [String] }

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var daemon: URL { root.appendingPathComponent("daemon") }
    static var python: URL { daemon.appendingPathComponent(".venv/bin/python") }

    @Test func theNewBriefPassesEveryScenarioThreeTimesInThree() async throws {
        guard let claude = HarnessCommandRunner.live.locate(AgentKind.claude.harness.executable) else {
            try Test.cancel("claude is not installed, so the Operator's brief was not checked.")
        }
        let environment = ProcessInfo.processInfo.environment
        let out = environment["AITERM_EVAL_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-operator-eval-\(Int(Date().timeIntervalSince1970))")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let fixtures = Self.root.appendingPathComponent("app/Tests/AiTermCoreTests/Operators/Fixtures/operator-current")
        let baseline = Brief(name: "baseline", brief: fixtures.appendingPathComponent("eval-brief.md"),
                             tools: Self.daemon.appendingPathComponent("tests/fixtures/operator-current-tools.json"))
        let new = Brief(name: "new", brief: out.appendingPathComponent("new-brief.md"), tools: out.appendingPathComponent("new-tools.json"))
        try Data(OperatorCommand.brief(run: OperatorEvalGrading.evalRun, projects: [OperatorEvalGrading.evalProject]).utf8).write(to: new.brief)
        try Self.dumpTools(to: new.tools)
        let (model, effort) = Self.model(environment)
        print("LIVE Operator evals: \(model)\(effort.map { " at \($0)" } ?? ""), runs kept in \(out.path)")

        let jobs = OperatorEvalGrading.scenarios.flatMap { scenario in
            [baseline, new].flatMap { brief in (1...Self.runsPerBrief).map { Job(scenario: scenario, brief: brief, number: $0) } }
        }
        let words = Array(AgentKind.claude.harness.launchWords(model: model, reasoning: effort).dropFirst())
        let outcomes = await withTaskGroup(of: Outcome.self) { group in
            var pending = jobs[...], done: [Outcome] = []
            func next() {
                guard let job = pending.popFirst() else { return }
                group.addTask { Self.run(job, claude: claude, words: words, in: out) }
            }
            for _ in 0..<Self.atOnce { next() }
            for await outcome in group {
                print("LIVE \(outcome.scenario) \(outcome.brief) #\(outcome.number): "
                      + (outcome.failures.isEmpty ? "pass" : outcome.failures.joined(separator: "; ")))
                done.append(outcome)
                next()
            }
            return done
        }

        let table = Self.table(outcomes)
        print(table)
        try Data(table.utf8).write(to: out.appendingPathComponent("table.txt"))
        for scenario in OperatorEvalGrading.scenarios {
            let missed = outcomes.filter { $0.scenario == scenario.name && $0.brief == "new" && !$0.failures.isEmpty }
            guard !missed.isEmpty else { continue }
            let runs = missed.sorted { $0.number < $1.number }.map { "#\($0.number) \($0.failures.joined(separator: "; "))" }
            Issue.record("The new brief missed \(scenario.name) \(missed.count) of \(Self.runsPerBrief): \(runs.joined(separator: " | "))")
        }
    }

    /// One run: the stub on a free port with the scenario's replies, `claude -p` with the brief and an `mcp.json` that
    /// reaches the stub as AiTerm's reaches `/operator`, then the grade. Its files stay in `<out>/<scenario>/<brief>-<n>`.
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
                                     "--output-format", "json", "--no-session-persistence",
                                     "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config", job.scenario.firstMessage]
            let result = try ProcessRunner.run(URL(fileURLWithPath: claude), arguments, in: folder, timeout: runTimeout)
            try Data(result.stdout.utf8).write(to: folder.appendingPathComponent("claude.json"))
            try Data(result.stderr.utf8).write(to: folder.appendingPathComponent("claude.stderr"))
            let answer = try? JSONDecoder().decode(JSONValue.self, from: Data(result.stdout.utf8))
            let transcript = EvalTranscript(calls: calls(in: log), reply: answer?["result"]?.stringValue ?? "")
            try Data(transcript.reply.utf8).write(to: folder.appendingPathComponent("reply.md"))
            var failures = job.scenario.check(transcript)
            if result.timedOut { failures.insert("the run timed out after \(Int(runTimeout)) s", at: 0) }
            else if answer?["subtype"]?.stringValue == "error_max_turns" { failures.insert("the run reached \(maxTurns) turns", at: 0) }
            else if answer == nil { failures.insert("claude answered no JSON (exit \(result.status))", at: 0) }
            return outcome(failures)
        } catch {
            return outcome(["the run couldn't start: \(error)"])
        }
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
    static func table(_ outcomes: [Outcome]) -> String {
        let width = OperatorEvalGrading.scenarios.map(\.name.count).max() ?? 0
        func passed(_ scenario: String, _ brief: String) -> String {
            "\(outcomes.filter { $0.scenario == scenario && $0.brief == brief && $0.failures.isEmpty }.count)/\(runsPerBrief)"
        }
        let pad = { (text: String) in text.padding(toLength: width, withPad: " ", startingAt: 0) }
        return ([pad("scenario") + "  baseline  new"] + OperatorEvalGrading.scenarios.map {
            pad($0.name) + "  " + passed($0.name, "baseline") + "  " + passed($0.name, "new")
        }).joined(separator: "\n")
    }
}
