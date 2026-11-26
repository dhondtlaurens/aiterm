import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct AgentCommandTests {
    let wt = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)").path

    /// Fully resolves symlinks in `path` using POSIX `realpath(3)`, matching what real `git`
    /// reports. See `WorktreesTests.realPath` for the rationale.
    private static func realPath(_ path: String) -> String {
        guard let cResolved = realpath(path, nil) else { return path }
        defer { free(cResolved) }
        return String(cString: cResolved)
    }

    @Test func testShellQuote() {
        #expect(AgentCommand.shellQuote("plain") == "'plain'")
        #expect(AgentCommand.shellQuote("it's \"x\" $HOME") == #"'it'\''s "x" $HOME'"#)
    }

    @Test func testClaudeAndCodexCommands() throws {
        #expect(try AgentCommand.build(agent: .claude, model: "opus", reasoning: "high", prompt: "/plan fix it", worktreePath: wt, git: .hermetic()) == "claude --model opus --effort high '/plan fix it'")
        #expect(try AgentCommand.build(agent: .claude, model: "opus", reasoning: nil, prompt: nil, worktreePath: wt, git: .hermetic()) == "claude --model opus")
        #expect(try AgentCommand.build(agent: .codex, model: "gpt-5.6", reasoning: "medium", prompt: "review", worktreePath: wt, git: .hermetic()) == "codex --dangerously-bypass-approvals-and-sandbox -m gpt-5.6 -c model_reasoning_effort=medium 'review'")
    }

    @Test func testPiCommandUsesQualifiedModelAndThinking() throws {
        #expect(try AgentCommand.build(agent: .pi, model: "openai-codex/gpt-5.6-sol",
                                       reasoning: "high", prompt: "review", worktreePath: wt, git: .hermetic())
                == "pi --model openai-codex/gpt-5.6-sol --thinking high 'review'")
        #expect(try AgentCommand.build(agent: .pi, model: "anthropic/claude-sonnet",
                                            reasoning: nil, prompt: nil, worktreePath: wt, git: .hermetic())
                == "pi --model anthropic/claude-sonnet")
    }

    /// Antigravity approves its own tools on every launch, and its model id names the effort: no
    /// reasoning word is sent, whatever the task saved. Its launch prompt follows `-i`: given alone it
    /// lands in the input unsent (agy 1.5.18), and the task would wait.
    @Test func agyCommandSkipsPermissionsAndSendsOnlyTheModel() throws {
        #expect(try AgentCommand.build(agent: .agy, model: "gemini-4-neon-high", reasoning: "high", prompt: "review",
                                       worktreePath: wt, git: .hermetic())
                == "agy --dangerously-skip-permissions --model gemini-4-neon-high -i 'review'")
        #expect(try AgentCommand.build(agent: .agy, model: "gemini-3.8-flash-low", reasoning: nil, prompt: nil,
                                       worktreePath: wt, git: .hermetic())
                == "agy --dangerously-skip-permissions --model gemini-3.8-flash-low")
    }

    /// A long launch prompt read from its file still follows `-i`.
    @Test func agyLongPromptFromItsFileFollowsItsFlag() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-agy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let command = try AgentCommand.build(agent: .agy, model: "gemini-4-neon-high", reasoning: nil,
                                             prompt: String(repeating: "x", count: 5000), worktreePath: dir.path, git: .hermetic())
        #expect(command.hasSuffix(#"-i "$(command cat .aiterm/first-prompt.md)""#))
    }

    /// An Antigravity review tab approves its own tools but may not write a file or write through git.
    @Test func agyReviewWorkerCannotWrite() {
        #expect(AgentCommand.workerWords(agent: .agy, model: "gemini-4-neon-high", reasoning: nil, readOnly: true) == [
            "agy", "--dangerously-skip-permissions", "--settings",
            #"{"permissions":{"deny":["write_file(*)","command(git commit)","command(git checkout)","command(git switch)","command(git reset)","command(git rebase)","command(git merge)","command(git stash)","command(git add)"]}}"#,
            "--model", "gemini-4-neon-high"])
        #expect(AgentCommand.workerWords(agent: .agy, model: "gemini-4-neon-high", reasoning: nil)
                == ["agy", "--dangerously-skip-permissions", "--model", "gemini-4-neon-high"])
    }

    /// The Oracle's Antigravity run: one answer as JSON, its folders trusted and every write, command,
    /// MCP call and fetch denied for this run only.
    @Test func agyOracleRunsReadOnlyThroughItsDenyRules() throws {
        let run = Harness.agy.readOnlyHeadless(prompt: "-why?", folder: "/repo", readable: ["/notes"], answerFile: "/tmp/a",
                                               model: "gemini-4-neon-high", reasoning: "high")
        #expect(run.executable == "agy")
        #expect(run.answerFile == nil)
        #expect(run.arguments == ["-p", "-why?", "--output-format", "json", "--settings",
                                  #"{"permissions":{"deny":["command(*)","write_file(*)","mcp(*)","url(*)","unsandboxed(*)"]},"trustedWorkspaces":["/repo","/notes"]}"#,
                                  "--add-dir", "/notes", "--model", "gemini-4-neon-high"])
        #expect(Harness.agy.headlessAnswer(#"{"conversation_id":"c","status":"SUCCESS","response":"PONG"}"#, nil) == "PONG")
        #expect(Harness.agy.headlessAnswer(#"{"status":"ERROR","response":"half an answer"}"#, nil) == nil)
        #expect(Harness.agy.headlessAnswer("not json", nil) == nil)
    }

    /// The command is typed into zsh, where an unquoted `[1m]` is a glob that matches nothing and
    /// fails the whole line with "no matches found". A word only shell-safe characters make up is
    /// left as it is, so every command above stays readable.
    @Test func testAWordZshWouldExpandIsQuoted() throws {
        #expect(try AgentCommand.build(agent: .claude, model: "claude-fable-5-1[1m]", reasoning: "max*", prompt: nil, worktreePath: wt, git: .hermetic())
                == "claude --model 'claude-fable-5-1[1m]' --effort 'max*'")
        #expect(try AgentCommand.build(agent: .codex, model: "gpt-5.6", reasoning: "x y", prompt: nil, worktreePath: wt, git: .hermetic())
                == "codex --dangerously-bypass-approvals-and-sandbox -m gpt-5.6 -c 'model_reasoning_effort=x y'")
        #expect(AgentCommand.shellWord("openai-codex/gpt-5.6-sol") == "openai-codex/gpt-5.6-sol")
        #expect(AgentCommand.shellWord("") == "''")
        // zsh's EQUALS option expands a word that starts with `=` to the path of that command.
        #expect(AgentCommand.shellWord("=ls") == "'=ls'")
        #expect(AgentCommand.shellWord("model_reasoning_effort=high") == "model_reasoning_effort=high")
    }

    @Test func testLongPromptGoesToFile() throws {
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        let long = String(repeating: "x", count: 9000)
        let cmd = try AgentCommand.build(agent: .claude, model: "opus", reasoning: nil, prompt: long, worktreePath: wt, git: .hermetic())
        #expect(cmd == "claude --model opus \"$(command cat .aiterm/first-prompt.md)\"")
        #expect(try String(contentsOfFile: wt + "/.aiterm/first-prompt.md", encoding: .utf8) == long)
    }

    /// An extra worker tab's prompt goes to a file of its own: the task's first worker, started in the same
    /// worktree, may not have read its own yet.
    @Test func testALongPromptGoesToTheFileNamed() throws {
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        let long = String(repeating: "y", count: 9000)
        let cmd = try AgentCommand.build(agent: .claude, model: "opus", reasoning: nil, prompt: long, worktreePath: wt, git: .hermetic(),
                                         promptFile: "first-prompt-tab.md")
        #expect(cmd == "claude --model opus \"$(command cat .aiterm/first-prompt-tab.md)\"")
        #expect(try String(contentsOfFile: wt + "/.aiterm/first-prompt-tab.md", encoding: .utf8) == long)
        #expect(!FileManager.default.fileExists(atPath: wt + "/.aiterm/first-prompt.md"))
    }

    /// Typed into the person's own shell, the command reads the file past any alias or function of
    /// theirs named `cat`, and hands the agent the prompt byte for byte, whatever it holds.
    @Test(arguments: [("/bin/zsh", "alias cat='tr a-z A-Z'"), ("/bin/zsh", "cat() { echo replaced; }"),
                      ("/bin/bash", "cat() { echo replaced; }"), ("/bin/sh", "cat() { echo replaced; }")])
    func testAPromptFromTheFileArrivesWholePastTheShellsOwnCat(shell: String, definition: String) throws {
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        let prompt = TypedText.text("Prompt", bytes: 110_000)
        let cmd = try AgentCommand.build(agent: .claude, model: "opus", reasoning: nil, prompt: prompt, worktreePath: wt, git: .hermetic())

        let ran = try ShellLine.run(shell, definition + "\nclaude() { /usr/bin/printf '%s\\0' \"$@\"; }\neval \"$1\"", argument: cmd,
                                    in: URL(fileURLWithPath: wt))

        #expect(ran.status == 0)
        // A pasted Windows line end is a newline, as `build` has always written it.
        #expect(ran.out == ShellLine.printed(["--model", "opus", prompt.replacingOccurrences(of: "\r\n", with: "\n")]))
    }

    /// The command is typed into a tab whose shell may not have started its line editor yet. Until
    /// it does, the terminal is in canonical mode, where macOS keeps at most 1024 bytes of input
    /// (`MAX_CANON`) and silently drops the rest: a 1 kB prompt once lost its closing quote and
    /// left zsh waiting at `quote>`. So the limit is on the whole typed command, quoting included.
    @Test func testACommandTooLongForTheTerminalLineGoesToFile() throws {
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        let fits = String(repeating: "x", count: 900)
        #expect(try AgentCommand.build(agent: .claude, model: "opus", reasoning: nil, prompt: fits, worktreePath: wt, git: .hermetic())
                == "claude --model opus '\(fits)'")
        // Short as text, but each `'` is typed as four bytes once it is quoted.
        for prompt in [String(repeating: "x", count: 1100), String(repeating: "it's ", count: 150)] {
            let cmd = try AgentCommand.build(agent: .claude, model: "opus", reasoning: nil, prompt: prompt, worktreePath: wt, git: .hermetic())
            #expect(cmd == "claude --model opus \"$(command cat .aiterm/first-prompt.md)\"")
            #expect(try String(contentsOfFile: wt + "/.aiterm/first-prompt.md", encoding: .utf8) == prompt)
        }
    }

    /// A short prompt is typed into the terminal, where a TAB completes, a lone CR accepts the
    /// line and ESC, ^C or ^U edit it — so a prompt holding any of them goes through the file.
    /// Windows line endings are only newlines, and stay inline.
    @Test func testAPromptWithControlCharactersGoesToFile() throws {
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        for prompt in ["fix\tit", "one\rtwo", "stop\u{1B}here", "x\u{03}y", "x\u{7F}y"] {
            let cmd = try AgentCommand.build(agent: .claude, model: "opus", reasoning: nil, prompt: prompt, worktreePath: wt, git: .hermetic())
            #expect(cmd == "claude --model opus \"$(command cat .aiterm/first-prompt.md)\"", "\(prompt.debugDescription)")
            #expect(try String(contentsOfFile: wt + "/.aiterm/first-prompt.md", encoding: .utf8) == prompt)
        }
        let crlf = try AgentCommand.build(agent: .claude, model: "opus", reasoning: nil, prompt: "one\r\ntwo\n", worktreePath: wt, git: .hermetic())
        #expect(crlf == "claude --model opus 'one\ntwo\n'")
    }

    /// Writing the long prompt must also add `.aiterm/` to the worktree repository's
    /// exclude file, resolved via `git rev-parse --git-path info/exclude` run in the worktree
    /// (a worktree's `info/exclude` lives in the common dir, not `<worktree>/.git/info/exclude`).
    @Test func testLongPromptExcludesAitermDirectory() throws {
        let git = GitRunner.hermetic()
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        let repo = Self.realPath(raw)
        _ = try git.run(["init", "-q", "-b", "main"], in: repo)
        _ = try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)

        let long = String(repeating: "x", count: 9000)
        _ = try AgentCommand.build(agent: .claude, model: "opus", reasoning: nil, prompt: long, worktreePath: repo, git: .hermetic())

        let exclude = try String(contentsOfFile: repo + "/.git/info/exclude", encoding: .utf8)
        #expect(exclude.contains(".aiterm/"))
    }

    /// The same for a linked worktree: for a real `.worktrees/<slug>` linked worktree (created via
    /// `addTaskWorktree`, as production code does), `git rev-parse --git-path info/exclude` run
    /// inside the linked worktree returns an *absolute* path into the main repo's common dir, not a
    /// path relative to the worktree. Verifies the absolute-path branch of `excludeAitermDirectory`
    /// lands `.aiterm/` in the main repo's exclude file, and that building twice is idempotent
    /// (the line appears exactly once).
    @Test func testLongPromptExcludesAitermDirectoryInLinkedWorktree() throws {
        let git = GitRunner.hermetic()
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        let repo = Self.realPath(raw)
        _ = try git.run(["init", "-q", "-b", "main"], in: repo)
        _ = try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)

        let linkedPath = try Repository(repo, git: git).addTaskWorktree(slug: "web-1-thing", branch: "feat/web-1-thing", base: "main")

        let long = String(repeating: "x", count: 9000)
        _ = try AgentCommand.build(agent: .claude, model: "opus", reasoning: nil, prompt: long, worktreePath: linkedPath, git: .hermetic())
        _ = try AgentCommand.build(agent: .claude, model: "opus", reasoning: nil, prompt: long, worktreePath: linkedPath, git: .hermetic())

        let exclude = try String(contentsOfFile: repo + "/.git/info/exclude", encoding: .utf8)
        #expect(exclude.contains(".aiterm/"))
        let occurrences = exclude.components(separatedBy: ".aiterm/").count - 1
        #expect(occurrences == 1)
    }

    @Test func testComposePrompt() {
        let t = JiraTicket(key: "WEB-5447", summary: "Add graceful SIGTERM", description: "Drain in-flight tasks.", issueType: "Task", status: "In Progress", url: "https://x/browse/WEB-5447")
        let composed = AgentCommand.composePrompt(userText: "/plan first", ticket: t, appendTicket: true) ?? ""
        #expect(composed.hasPrefix("/plan first") && composed.contains("Drain in-flight tasks."))
        #expect(!composed.contains("WEB-5447") && !composed.contains("Add graceful SIGTERM"))
        #expect(AgentCommand.composePrompt(userText: nil, ticket: t, appendTicket: false) == nil)
        #expect(AgentCommand.composePrompt(userText: "  ", ticket: nil, appendTicket: true) == nil)
    }

    /// Each agent resumes by its CLI's own spelling, then takes the model and reasoning the task was
    /// launched with.
    @Test func eachAgentResumesItsConversationOnItsLaunchModel() {
        let id = "0199f5c2-7a1e-7d3b-9c41-2f6a8e0b1d57"
        #expect(AgentCommand.resume(agent: .claude, conversation: id, model: "opus", reasoning: "high")
                == "claude --resume \(id) --model opus --effort high")
        #expect(AgentCommand.resume(agent: .codex, conversation: id, model: "gpt-5.6", reasoning: "medium")
                == "codex resume \(id) --dangerously-bypass-approvals-and-sandbox -m gpt-5.6 -c model_reasoning_effort=medium")
        #expect(AgentCommand.resume(agent: .pi, conversation: id, model: "openai-codex/gpt-5.6-sol", reasoning: "high")
                == "pi --session \(id) --model openai-codex/gpt-5.6-sol --thinking high")
        #expect(AgentCommand.resume(agent: .agy, conversation: id, model: "gemini-4-neon-high", reasoning: nil)
                == "agy --conversation \(id) --dangerously-skip-permissions --model gemini-4-neon-high")
    }

    /// An agent started in a tab by hand has no launch model AiTerm knows: it resumes on its own defaults.
    @Test func aConversationWithoutItsLaunchModelResumesOnTheAgentsDefaults() {
        #expect(AgentCommand.resume(agent: .claude, conversation: "c-1", model: nil, reasoning: "high") == "claude --resume c-1")
        #expect(AgentCommand.resume(agent: .codex, conversation: "t-1", model: "", reasoning: nil) == "codex resume t-1")
    }

    /// The id comes from another process's hook: it is one word of the command, whatever it holds.
    @Test func aConversationIdIsOneWordOfTheCommand() {
        #expect(AgentCommand.resume(agent: .claude, conversation: "my session; rm -rf ~", model: nil, reasoning: nil)
                == "claude --resume 'my session; rm -rf ~'")
    }
}
