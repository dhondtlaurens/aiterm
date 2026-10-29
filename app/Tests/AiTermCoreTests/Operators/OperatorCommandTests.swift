import Testing
import Foundation
@testable import AiTermCore

@Suite struct OperatorCommandTests {
    typealias F = OperatorFixtures
    let token = String(repeating: "ab", count: 32)

    static func currentRun(_ variant: String) -> OperatorRun {
        F.run(oracle: variant != "minimal", slices: variant == "minimal" ? .none : Slices(jira: true, review: true, merge: true),
              agents: F.agents, taskSettings: TaskSettings(review: variant == "minimal" ? nil : "Review with /code-review.",
                                                         end: variant == "local-merge" ? .mergeLocal : variant == "minimal" ? .commit : .merge,
                                                         closeWhenDone: variant != "minimal", deleteMergedBranch: variant == "local-merge"),
              goal: variant == "all-on" ? F.goal : nil)
    }

    /// This is the model's execution contract, frozen before structural refactoring. It runs without
    /// invoking an agent, including when the optional real-agent evals are disabled.
    @Test(arguments: ["all-on", "minimal", "local-merge"])
    func currentBriefMatchesItsFrozenContract(variant: String) throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/operator-current/brief-" + variant + ".md")
        let expected = try String(contentsOf: file, encoding: .utf8)
        #expect(OperatorCommand.brief(run: Self.currentRun(variant), projects: [F.project()]) == expected)
    }

    @Test func evalSetupUsesTheCurrentStructuredContract() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/operator-current/eval-brief.md")
        let brief = OperatorCommand.brief(run: OperatorEvalGrading.evalRun, projects: [OperatorEvalGrading.evalProject])
        #expect(brief == (try String(contentsOf: file, encoding: .utf8)))
    }

    private func home() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("operator-home-\(UUID().uuidString)") }

    /// The line the Operator's window runs. With the gate's denials it is past the typed-line limit, so the window
    /// types `eval "$(command cat launch.sh)"` and the line itself is the run folder's `launch.sh`.
    private func line(of prepared: OperatorCommand.Prepared) throws -> String {
        #expect(prepared.command == "eval \"$(command cat launch.sh)\"")
        return try String(contentsOf: prepared.folder.appendingPathComponent(OperatorCommand.launchFile), encoding: .utf8)
    }

    @Test func theRunFolderIsUnderOperatorsRuns() {
        #expect(OperatorCommand.runFolder(F.runId, home: URL(fileURLWithPath: "/Users/someone")).path
                == "/Users/someone/Library/Application Support/AiTerm/operators/runs/1EB4C0DE-0000-0000-0000-0000000000AA")
    }

    @Test(arguments: [nil, "~/profiles/claude", "~/.claude", "absolute"] as [String?])
    func preparationTrustsOnlyItsOwnRunFolder(configPath: String?) throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = ClaudeConfig(configPath == "absolute" ? home.appendingPathComponent("external-profile").path : configPath)
        let prepared = try OperatorCommand.prepare(run: F.run(), projects: [F.project()], home: home, claudeConfig: config, token: token)
        let file = config.globalJSON(home: home)
        #expect(file.path.hasPrefix(home.path + "/"), "every profile in this test stays inside its temporary home")
        let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let projects = try #require(state["projects"] as? [String: [String: Any]])
        #expect(Set(projects.keys) == [VerifySandbox.realPath(prepared.folder.path)])
        #expect(projects.values.first?["hasTrustDialogAccepted"] as? Bool == true)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        if configPath != nil { #expect(!FileManager.default.fileExists(atPath: ClaudeConfig().globalJSON(home: home).path)) }
    }

    @Test func trustingTheRunPreservesTheRestOfClaudeStateAndItsSymlink() throws {
        let home = home(), fm = FileManager.default
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let runFolder = OperatorCommand.runFolder(F.runId, home: home)
        try fm.createDirectory(at: runFolder, withIntermediateDirectories: true)
        let folder = VerifySandbox.realPath(runFolder.path)
        let original: JSONValue = ["theme": "light", "future": ["keep": [1, true, nil]], "projects": .object([
            "/other": ["hasTrustDialogAccepted": false, "allowedTools": ["Read"]],
            folder: ["hasTrustDialogAccepted": false, "allowedTools": ["Grep"], "future": 42],
        ])]
        let bytes = try JSONEncoder().encode(original)
        let target = home.appendingPathComponent("dotfile.json"), file = ClaudeConfig().globalJSON(home: home)
        try bytes.write(to: target)
        try fm.createSymbolicLink(at: file, withDestinationURL: target)
        for resuming in [nil, "conv-1"] as [String?] {
            _ = try OperatorCommand.prepare(run: F.run(), projects: [], home: home, token: token, resuming: resuming)
            let state = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
            var expectedProjects = try #require(original["projects"]?.objectValue)
            expectedProjects[folder] = ["hasTrustDialogAccepted": true, "allowedTools": ["Grep"], "future": 42]
            var expected = try #require(original.objectValue)
            expected["projects"] = .object(expectedProjects)
            #expect(state == .object(expected))
            #expect(try fm.destinationOfSymbolicLink(atPath: file.path) == target.path)
            #expect(try fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == 0o600)
            #expect(try Data(contentsOf: file.appendingPathExtension("aiterm-backup")) == bytes)
            #expect(!fm.fileExists(atPath: file.path + ".lock"))
        }
    }

    @Test(arguments: ["broken", "[]", #"{"projects":null}"#, #"{"projects":[]}"#, "bad-record"])
    func malformedClaudeStateIsLeftIntactAndStopsPreparation(value: String) throws {
        let home = home(), fm = FileManager.default
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let folder = OperatorCommand.runFolder(F.runId, home: home), file = ClaudeConfig().globalJSON(home: home)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = value == "bad-record"
            ? try JSONEncoder().encode(JSONValue.object(["projects": .object([VerifySandbox.realPath(folder.path): []])]))
            : Data(value.utf8)
        try bytes.write(to: file)
        #expect(throws: HarnessDriverError.self) {
            try OperatorCommand.prepare(run: F.run(), projects: [], home: home, token: token)
        }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(!fm.fileExists(atPath: file.path + ".lock"))
        #expect(!fm.fileExists(atPath: file.appendingPathExtension("aiterm-backup").path))
        #expect(!fm.fileExists(atPath: folder.appendingPathComponent(OperatorCommand.launchFile).path))
    }

    @Test func aBusyClaudeConfigIsNeverWrittenOrUnlocked() throws {
        let home = home(), fm = FileManager.default
        defer { try? fm.removeItem(at: home) }
        let file = ClaudeConfig().globalJSON(home: home), lock = file.appendingPathExtension("lock")
        try fm.createDirectory(at: lock, withIntermediateDirectories: true)
        #expect(throws: HarnessDriverError.self) {
            try OperatorCommand.prepare(run: F.run(), projects: [], home: home, token: token)
        }
        #expect(fm.fileExists(atPath: lock.path))
        #expect(!fm.fileExists(atPath: file.path))
    }

    @Test func aDanglingClaudeStateLinkIsNotReplaced() throws {
        let home = home(), fm = FileManager.default
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let file = ClaudeConfig().globalJSON(home: home), missing = home.appendingPathComponent("missing.json")
        try fm.createSymbolicLink(at: file, withDestinationURL: missing)
        #expect(throws: HarnessDriverError.self) {
            try OperatorCommand.prepare(run: F.run(), projects: [], home: home, token: token)
        }
        #expect(try fm.destinationOfSymbolicLink(atPath: file.path) == missing.path)
        #expect(!fm.fileExists(atPath: missing.path))
        #expect(!fm.fileExists(atPath: file.path + ".lock"))
    }

    @Test func anAlreadyTrustedRunReopensWithoutTakingTheConfigLockOrWriting() throws {
        let home = home(), fm = FileManager.default
        defer { try? fm.removeItem(at: home) }
        _ = try OperatorCommand.prepare(run: F.run(), projects: [], home: home, token: token)
        let file = ClaudeConfig().globalJSON(home: home), lock = file.appendingPathExtension("lock")
        let before = try Data(contentsOf: file)
        let modified = try fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        try fm.createDirectory(at: lock, withIntermediateDirectories: false)
        _ = try OperatorCommand.prepare(run: F.run(), projects: [], home: home, token: token, resuming: "conv-1")
        #expect(try Data(contentsOf: file) == before)
        #expect(try fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == modified)
        #expect(fm.fileExists(atPath: lock.path))
    }

    @Test func concurrentPreparationsKeepEveryRunsTrust() async throws {
        let home = home(), runToken = token
        defer { try? FileManager.default.removeItem(at: home) }
        let folders = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<4 {
                var run = F.run()
                run.id = UUID()
                let fresh = run
                group.addTask {
                    try await BackgroundWork.run {
                        try OperatorCommand.prepare(run: fresh, projects: [], home: home, token: runToken).folder
                    }
                }
            }
            var result: [URL] = []
            for try await folder in group { result.append(folder) }
            return result
        }
        let state = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: ClaudeConfig().globalJSON(home: home)))
        #expect(state["projects"]?.objectValue?.count == folders.count)
        for folder in folders {
            #expect(state["projects"]?[VerifySandbox.realPath(folder.path)]?["hasTrustDialogAccepted"] == true)
        }
    }

    /// Spec §5's command, word for word, with the effort as the Claude harness passes it: Bash behind the
    /// gate hook (`--settings`), the hard denials, and `Bash` allowed so a failed hook never prompts.
    @Test func theOperatorLaunchesWithAGatedShellAndOnlyAiTermsServer() {
        let folder = URL(fileURLWithPath: "/runs/R")
        let words = OperatorCommand.launchWords(model: "claude-opus-5-5", effort: "high", runFolder: folder,
                                                projectPaths: ["/code/shop", "/code/pay"])
        #expect(words == ["claude", "--model", "claude-opus-5-5", "--effort", "high",
                          "--append-system-prompt-file", "/runs/R/brief.md", "--tools", "Read,Grep,Glob,Bash",
                          "--add-dir", "/code/shop", "--add-dir", "/code/pay",
                          "--settings", "/runs/R/gate.json", "--disallowedTools"] + OperatorCommand.shellDenials
                          + ["--mcp-config", "/runs/R/mcp.json", "--allowedTools", "mcp__aiterm__*", "Bash", "--strict-mcp-config"])
        #expect(OperatorCommand.command(words: words, firstMessage: true).hasSuffix(
            "--allowedTools 'mcp__aiterm__*' Bash --strict-mcp-config \"$(command cat first-message.md)\""))
    }

    /// The hard denials win over `Bash` being allowed: a worker's pushes and merges, plus the changes the
    /// Operator's shell must never make (commits, resets, checkouts, switches and cleans, through `-C` and
    /// `-c` too; closing, editing, reviewing, approving and commenting on a request), and no question tool.
    @Test func theShellDenialsKeepPushesCommitsAndCheckoutsOut() {
        let denials = OperatorCommand.shellDenials
        #expect(denials == AgentCommand.operatedClaudeDenials.filter { $0 != "AskUserQuestion" } + [
            "Bash(git commit:*)", "Bash(git * commit:*)", "Bash(git reset --hard:*)", "Bash(git checkout:*)",
            "Bash(git switch:*)", "Bash(git clean:*)", "Bash(git -C * checkout:*)", "Bash(git -C * reset:*)",
            "Bash(git -C * switch:*)", "Bash(git -C * clean:*)",
            "Bash(git -c * reset:*)", "Bash(git -c * checkout:*)", "Bash(git -c * switch:*)", "Bash(git -c * clean:*)",
            "Bash(gh pr close:*)", "Bash(gh pr reopen:*)", "Bash(gh pr edit:*)", "Bash(gh pr review:*)", "Bash(gh pr comment:*)",
            "Bash(glab mr close:*)", "Bash(glab mr reopen:*)", "Bash(glab mr approve:*)", "Bash(glab mr note:*)", "Bash(glab mr rebase:*)"])
        #expect(!denials.contains("AskUserQuestion") && denials.contains("Bash(git push:*)"))
        // The worker's host denials are kept, not forked: merges, creations, ready and updates.
        for kept in ["Bash(gh pr merge:*)", "Bash(glab mr merge:*)", "Bash(gh pr ready:*)", "Bash(glab mr update:*)", "Bash(git -C * push:*)"] {
            #expect(denials.contains(kept), "\(kept)")
        }
    }

    /// Spec §9: a gone operator session is relaunched on its conversation, under the same profile.
    @Test func aResumedOperatorKeepsItsProfile() {
        let words = OperatorCommand.launchWords(model: "opus", effort: nil, runFolder: URL(fileURLWithPath: "/r"),
                                                projectPaths: [], resuming: "conv-1")
        #expect(Array(words.prefix(5)) == ["claude", "--resume", "conv-1", "--model", "opus"])
        #expect(words.contains("--strict-mcp-config") && words.contains("Read,Grep,Glob,Bash"))
        #expect(words.joined(separator: " ").contains("--settings /r/gate.json --disallowedTools"))
        #expect(words.last == "--strict-mcp-config")
        #expect(words.joined(separator: " ").contains("--system-prompt-snapshot off --append-system-prompt-file /r/brief.md"))
    }

    /// Part B's contract: server `aiterm`, type `http`, the `/operator` route on the hook port, the
    /// bearer token and the `X-AiTerm-Hook` header, which every hook-port route requires.
    @Test func mcpJSONReachesTheOperatorRouteWithTheBearerToken() throws {
        let json = try OperatorCommand.mcpConfig(hookPort: 47821, token: "t0k")
        #expect(json == #"{"mcpServers":{"aiterm":{"headers":{"Authorization":"Bearer t0k","X-AiTerm-Hook":"1"},"type":"http","url":"http://127.0.0.1:47821/operator"}}}"#)
    }

    /// The Operator's shell: every Bash call goes to `/operator/gate` as a PreToolUse hook with the run's
    /// bearer token. The hook outlasts the daemon's 200 s gate wait (240 s), and Claude's own output cap
    /// is `BASH_MAX_OUTPUT_LENGTH`.
    @Test func gateSettingsReachTheGateRouteWithTheBearerToken() throws {
        let json = try OperatorCommand.gateSettings(hookPort: 47821, token: "t0k")
        #expect(json == #"{"env":{"BASH_MAX_OUTPUT_LENGTH":"16000"},"hooks":{"PreToolUse":[{"hooks":[{"headers":{"Authorization":"Bearer t0k","X-AiTerm-Hook":"1"},"timeout":240,"type":"http","url":"http://127.0.0.1:47821/operator/gate"}],"matcher":"Bash"}]}}"#)
    }

    @Test func prepareWritesTheGatePrivately() throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        for resuming in [nil, "conv-1"] as [String?] {
            let prepared = try OperatorCommand.prepare(run: F.run(), projects: [], hookPort: 5000, home: home, token: token, resuming: resuming)
            let file = prepared.folder.appendingPathComponent(OperatorCommand.gateFile)
            #expect(OperatorCommand.gateFile == "gate.json")
            #expect(try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
            #expect(try String(contentsOf: file, encoding: .utf8) == OperatorCommand.gateSettings(hookPort: 5000, token: token))
            #expect(try line(of: prepared).contains("--settings \(AgentCommand.shellWord(file.path))"))
        }
    }

    @Test func aTokenIs32RandomBytesInHex() {
        let a = OperatorCommand.makeToken(), b = OperatorCommand.makeToken()
        #expect(a.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
        #expect(a != b)
    }

    @Test func preparingWritesTheRunFolderWithTheTokenPrivate() throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = F.project(path: "/code/shop dir")

        let prepared = try OperatorCommand.prepare(run: F.run(), projects: [project], hookPort: 5000, home: home, token: token)

        let folder = OperatorCommand.runFolder(F.runId, home: home)
        #expect(prepared.folder.path == folder.path && prepared.token == token)
        func mode(_ name: String) throws -> Int {
            try #require(FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.posixPermissions] as? Int)
        }
        #expect(try mode(OperatorCommand.tokenFile) == 0o600)
        #expect(try mode(OperatorCommand.mcpFile) == 0o600)
        #expect(try #require(FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int) == 0o700)
        #expect(OperatorCommand.existingToken(in: folder) == token)
        #expect(try String(contentsOf: folder.appendingPathComponent(OperatorCommand.tokenFile), encoding: .utf8) == token,
                "exactly the 64 hex digits, as the daemon reads them")
        #expect(try String(contentsOf: folder.appendingPathComponent(OperatorCommand.mcpFile), encoding: .utf8)
                == OperatorCommand.mcpConfig(hookPort: 5000, token: token))
        #expect(try String(contentsOf: folder.appendingPathComponent(OperatorCommand.firstMessageFile), encoding: .utf8)
                == "Your broadcast:\n\nImplement the sprint.")
        #expect(try String(contentsOf: folder.appendingPathComponent(OperatorCommand.briefFile), encoding: .utf8)
                .contains("Ask before adding a field a ticket doesn't mention."))
        let typed = try line(of: prepared)
        #expect(typed.contains("--add-dir '/code/shop dir'"))
        #expect(typed.contains("'\(folder.appendingPathComponent("brief.md").path)'"))
        #expect(typed.hasSuffix("\"$(command cat first-message.md)\""))
        #expect(try mode(OperatorCommand.launchFile) == 0o600)
        // No leftover temporary files beside them.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
                == ["brief.md", "first-message.md", "gate.json", "launch.sh", "mcp.json", "token"])
    }

    /// The first message is `claude`'s prompt argument: a pasted bullet list must never lead it.
    @Test func aBriefStartingWithADashNeverLeadsTheFirstMessage() throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        var run = F.run()
        run.prompt = "- fix login\n- add tests"

        let prepared = try OperatorCommand.prepare(run: run, projects: [], home: home, token: token)

        let text = try String(contentsOf: prepared.folder.appendingPathComponent(OperatorCommand.firstMessageFile), encoding: .utf8)
        #expect(text.first != "-")
        #expect(text.contains("- fix login\n- add tests"))
    }

    @Test func aResumeSendsNoFirstMessageAndRewritesTheToken() throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try OperatorCommand.prepare(run: F.run(), projects: [], home: home, token: OperatorCommand.makeToken())

        let resumed = try OperatorCommand.prepare(run: F.run(), projects: [], home: home, token: token, resuming: "conv-1")

        let typed = try line(of: resumed)
        #expect(!typed.contains("first-message.md"))
        #expect(typed.hasPrefix("claude --resume conv-1 --model claude-opus-5-5 --effort high"))
        #expect(OperatorCommand.existingToken(in: resumed.folder) == token)
    }

    @Test func saidTrimsAndDropsEmptyText() {
        #expect(OperatorCommand.said("  fix it \n") == "fix it")
        #expect(OperatorCommand.said("  \n") == nil)
        #expect(OperatorCommand.said(nil) == nil)
    }

    @Test func theLaunchGivesTheShellAndKeepsTheOtherLimits() throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        let prepared = try OperatorCommand.prepare(run: F.run(slices: Slices(jira: true, review: true, merge: true)), projects: [F.project()],
                                                   home: home, token: token)
        let typed = try line(of: prepared)
        #expect(typed.contains("--tools Read,Grep,Glob,Bash"))
        #expect(typed.contains("--disallowedTools 'Bash(git push:*)'"))
        #expect(!typed.contains("AskUserQuestion"))
        #expect(typed.contains("--allowedTools 'mcp__aiterm__*' Bash --strict-mcp-config \"$(command cat first-message.md)\""))
    }

    @Test func theLaunchUsesTheFrozenProfilesModel() throws {
        let home = home()
        defer { try? FileManager.default.removeItem(at: home) }
        var run = F.run()
        run.profile.model = "claude-sonnet-5"
        run.profile.reasoning = "low"
        let prepared = try OperatorCommand.prepare(run: run, projects: [], home: home, token: token)
        #expect(try line(of: prepared).hasPrefix("claude --model claude-sonnet-5 --effort low"))
    }

    @Test(arguments: [false, true], [false, true])
    func newBroadcastFirstMessageUsesTaskReviewAndGoal(review: Bool, goal: Bool) {
        var run = newBroadcast()
        run.taskSettings.review = review ? "  Review every commit. \n" : nil
        run.goal = goal ? BroadcastGoal(text: "  The release is ready. \n", extraRounds: 2) : nil
        let expected = "Your broadcast:\n\nImplement the sprint."
            + (review ? "\n\nEach task is reviewed with: Review every commit." : "")
            + (goal ? "\n\nGoal: The release is ready." : "")
        #expect(OperatorCommand.firstMessage(for: run) == expected)
    }

    @Test(arguments: [false, true], [false, true])
    func newBroadcastClosingHonoursBothSettings(close: Bool, delete: Bool) {
        var run = newBroadcast()
        run.taskSettings.closeWhenDone = close
        run.taskSettings.deleteMergedBranch = delete
        let broadcast = section("## This broadcast", of: OperatorCommand.brief(run: run, projects: []))
        #expect(broadcast.contains(close ? "Closing: close finished tasks' tabs" : "Closing: keep tabs, worktrees and local branches"))
        #expect(broadcast.contains("delete their local branches once merged into the default branch") == (close && delete))
    }

    @Test func blankReviewAndGoalAreOmittedFromTheFirstMessage() {
        var run = newBroadcast()
        run.taskSettings.review = " \n "
        run.goal = BroadcastGoal(text: " \n ")
        #expect(OperatorCommand.firstMessage(for: run) == "Your broadcast:\n\nImplement the sprint.")
    }

    @Test(arguments: TaskEnd.allCases)
    func newBroadcastNamesItsChosenEnd(end: TaskEnd) {
        var run = newBroadcast()
        run.taskSettings.end = end
        let brief = OperatorCommand.brief(run: run, projects: [])
        #expect(section("## This broadcast", of: brief).contains("End: " + end.displayName))
        #expect(section("## The end", of: brief).contains("Every task ends at " + end.displayName))
    }

    @Test func theBriefNamesItsJiraProjectsAndAFreshStartEachDecisionsWhy() {
        var run = F.run()
        run.jiraProjectKeys = ["PAY", "SHOP"]
        run.decisions = [OperatorDecision(key: "d", text: "Kept the endpoint.", task: nil, at: F.epoch, why: "Clients still use it.")]
        #expect(OperatorCommand.brief(run: run, projects: []).contains("Jira projects: PAY, SHOP"))
        #expect(OperatorCommand.freshStartMessage(for: run, status: "{}").contains("Kept the endpoint. Why: Clients still use it."))
    }

    private func newBroadcast() -> OperatorRun {
        var run = F.run(slices: Slices(jira: true, review: true, merge: true))
        run.agents = [AgentChoice(agent: .claude, model: "opus", reasoning: "high"),
                      AgentChoice(agent: .codex, model: "gpt", reasoning: nil)]
        run.taskSettings = TaskSettings(review: nil, end: .mergeLocal)
        return run
    }

    private func section(_ heading: String, of brief: String) -> String {
        guard let start = brief.range(of: "\n" + heading + "\n") else { return "" }
        let rest = brief[start.upperBound...]
        return String(rest[..<(rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex)])
    }
}
