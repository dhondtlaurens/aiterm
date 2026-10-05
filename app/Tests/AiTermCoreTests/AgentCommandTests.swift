import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct AgentCommandTests {
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

    @Test func grokCommand() {
        #expect(AgentCommand.previewCommand(agent: .grok, model: "grok-4.7", reasoning: "high", prompt: "fix it")
                == "grok -m grok-4.7 --reasoning-effort high 'fix it'")
        #expect(AgentCommand.previewCommand(agent: .grok, model: "grok-4.5", reasoning: nil, prompt: nil)
                == "grok -m grok-4.5")
    }

    @Test func testPiCommandUsesQualifiedModelAndThinking() throws {
        #expect(try AgentCommand.build(agent: .pi, model: "openai-codex/gpt-5.6-sol",
                                       reasoning: "high", prompt: "review", worktreePath: wt, git: .hermetic())
                == "pi --model openai-codex/gpt-5.6-sol --thinking high 'review'")
        #expect(AgentCommand.previewCommand(agent: .pi, model: "anthropic/claude-sonnet",
                                            reasoning: nil, prompt: nil)
                == "pi --model anthropic/claude-sonnet")
    }

    /// The command is typed into zsh, where an unquoted `[1m]` is a glob that matches nothing and
    /// fails the whole line with "no matches found". A word only shell-safe characters make up is
    /// left as it is, so every command above stays readable.
    @Test func testAWordZshWouldExpandIsQuoted() throws {
        #expect(try AgentCommand.build(agent: .claude, model: "claude-fable-5-1[1m]", reasoning: "max*", prompt: nil, worktreePath: wt, git: .hermetic())
                == "claude --model 'claude-fable-5-1[1m]' --effort 'max*'")
        #expect(AgentCommand.previewCommand(agent: .codex, model: "gpt-5.6", reasoning: "x y", prompt: nil)
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
        #expect(cmd == "claude --model opus \"$(cat .aiterm/first-prompt.md)\"")
        #expect(try String(contentsOfFile: wt + "/.aiterm/first-prompt.md", encoding: .utf8) == long)
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
            #expect(cmd == "claude --model opus \"$(cat .aiterm/first-prompt.md)\"")
            #expect(try String(contentsOfFile: wt + "/.aiterm/first-prompt.md", encoding: .utf8) == prompt)
            #expect(AgentCommand.previewCommand(agent: .claude, model: "opus", reasoning: nil, prompt: prompt) == cmd)
        }
    }

    /// A short prompt is typed into the terminal, where a TAB completes, a lone CR accepts the
    /// line and ESC, ^C or ^U edit it — so a prompt holding any of them goes through the file.
    /// Windows line endings are only newlines, and stay inline.
    @Test func testAPromptWithControlCharactersGoesToFile() throws {
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        for prompt in ["fix\tit", "one\rtwo", "stop\u{1B}here", "x\u{03}y", "x\u{7F}y"] {
            let cmd = try AgentCommand.build(agent: .claude, model: "opus", reasoning: nil, prompt: prompt, worktreePath: wt, git: .hermetic())
            #expect(cmd == "claude --model opus \"$(cat .aiterm/first-prompt.md)\"", "\(prompt.debugDescription)")
            #expect(try String(contentsOfFile: wt + "/.aiterm/first-prompt.md", encoding: .utf8) == prompt)
            #expect(AgentCommand.previewCommand(agent: .claude, model: "opus", reasoning: nil, prompt: prompt) == cmd)
        }
        let crlf = try AgentCommand.build(agent: .claude, model: "opus", reasoning: nil, prompt: "one\r\ntwo\n", worktreePath: wt, git: .hermetic())
        #expect(crlf == "claude --model opus 'one\ntwo\n'")
        #expect(AgentCommand.previewCommand(agent: .claude, model: "opus", reasoning: nil, prompt: "one\r\ntwo") == "claude --model opus 'one\ntwo'")
    }

    /// Ruling P3: writing the long prompt must also add `.aiterm/` to the worktree repository's
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

    /// Ruling P3, linked-worktree case: for a real `.worktrees/<slug>` linked worktree (created via
    /// `Worktrees.create`, as production code does), `git rev-parse --git-path info/exclude` run
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

        let linkedPath = try Worktrees.create(repo: repo, slug: "web-1-thing", branch: "feat/web-1-thing", base: "main", git: git)

        let long = String(repeating: "x", count: 9000)
        _ = try AgentCommand.build(agent: .claude, model: "opus", reasoning: nil, prompt: long, worktreePath: linkedPath, git: .hermetic())
        _ = try AgentCommand.build(agent: .claude, model: "opus", reasoning: nil, prompt: long, worktreePath: linkedPath, git: .hermetic())

        let exclude = try String(contentsOfFile: repo + "/.git/info/exclude", encoding: .utf8)
        #expect(exclude.contains(".aiterm/"))
        let occurrences = exclude.components(separatedBy: ".aiterm/").count - 1
        #expect(occurrences == 1)
    }

    /// Final review item H: the New Task footer must show the exact command before any worktree
    /// exists, so the preview never touches the disk and switches to the `$(cat …)` form at the same
    /// threshold `build` uses.
    @Test func testPreviewCommandMatchesBuildWithoutTouchingDisk() {
        #expect(AgentCommand.previewCommand(agent: .claude, model: "opus", reasoning: "high", prompt: "/plan fix it") == "claude --model opus --effort high '/plan fix it'")
        #expect(AgentCommand.previewCommand(agent: .codex, model: "gpt-5.6", reasoning: nil, prompt: nil) == "codex --dangerously-bypass-approvals-and-sandbox -m gpt-5.6")

        let long = String(repeating: "x", count: 9000)
        #expect(AgentCommand.previewCommand(agent: .claude, model: "opus", reasoning: nil, prompt: long) == "claude --model opus \"$(cat .aiterm/first-prompt.md)\"")
        #expect(!FileManager.default.fileExists(atPath: wt), "the preview must not create a worktree directory")
    }

    @Test func testComposePrompt() {
        let t = JiraTicket(key: "WEB-5447", summary: "Add graceful SIGTERM", description: "Drain in-flight tasks.", issueType: "Task", status: "In Progress", url: "https://x/browse/WEB-5447")
        #expect(AgentCommand.composePrompt(userText: "/plan first", ticket: t, appendTicket: true) ==
                       "/plan first\n\nWEB-5447: Add graceful SIGTERM\n\nDrain in-flight tasks.")
        #expect(AgentCommand.composePrompt(userText: nil, ticket: t, appendTicket: false) == nil)
        #expect(AgentCommand.composePrompt(userText: "  ", ticket: nil, appendTicket: true) == nil)
    }
}
