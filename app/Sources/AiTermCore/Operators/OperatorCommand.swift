import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The operator's launch (spec §5): its run folder, the `brief.md` it is given as its system
/// prompt, the `mcp.json` that reaches AiTerm's `/operator` route with the run's token, and the
/// `claude …` command its window runs, from that folder.
///
/// The command is what makes "the operator writes no code" true rather than asked for: `--tools`
/// leaves it Read, Grep, Glob and a Bash that `gate.json`'s PreToolUse hook sends to the daemon's
/// `/operator/gate` (reads at once, the rest to the Oracle), `--disallowedTools` refuses what no
/// answer unlocks, `--strict-mcp-config` leaves it no MCP server but AiTerm's, and `--allowedTools`
/// lets those tools run without a prompt: `Bash` too, so a hook that fails never becomes a prompt in
/// its window (a hard denial wins over it).
public enum OperatorCommand {
    public static let briefFile = "brief.md", mcpFile = "mcp.json", gateFile = "gate.json", tokenFile = "token",
        firstMessageFile = "first-message.md", launchFile = "launch.sh"

    /// What the Operator's shell is refused whatever the Oracle says: a worker's denials (push, merge, MR
    /// changes; `AskUserQuestion` is not a Bash tool and is left out, as the Operator has `ask_you`),
    /// plus the changes to a checkout that only a worker's task makes: commits, hard resets, branch
    /// switches and cleans, also through `git -C` and `git -c`, and the other changes to a request on
    /// the host: closing, editing, reviewing, approving and commenting. Pushes stay with `finish_task`.
    /// The gate refuses the same from the parsed words (`ShellGate.hardDenial`); these are Claude's
    /// backstop, for a command that reaches no gate because AiTerm isn't there.
    public static let shellDenials = AgentCommand.operatedClaudeDenials.filter { $0 != "AskUserQuestion" } + [
        "Bash(git commit:*)", "Bash(git * commit:*)", "Bash(git reset --hard:*)", "Bash(git checkout:*)", "Bash(git switch:*)",
        "Bash(git clean:*)", "Bash(git -C * checkout:*)", "Bash(git -C * reset:*)", "Bash(git -C * switch:*)", "Bash(git -C * clean:*)",
        "Bash(git -c * reset:*)", "Bash(git -c * checkout:*)", "Bash(git -c * switch:*)", "Bash(git -c * clean:*)",
        "Bash(gh pr close:*)", "Bash(gh pr reopen:*)", "Bash(gh pr edit:*)", "Bash(gh pr review:*)", "Bash(gh pr comment:*)",
        "Bash(glab mr close:*)", "Bash(glab mr reopen:*)", "Bash(glab mr approve:*)", "Bash(glab mr note:*)", "Bash(glab mr rebase:*)",
    ]

    /// `operators/runs/<run-id>/` in AiTerm's support folder: outside every worktree.
    public static func runFolder(_ runId: UUID, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        AiTermPaths.supportDirectory(home: home).appendingPathComponent("operators")
            .appendingPathComponent("runs").appendingPathComponent(runId.uuidString)
    }

    /// The command's words, unquoted. Model and effort go as the Claude harness passes them
    /// (`--model`, `--effort`); `resuming` is the conversation `claude --resume` continues (§9).
    /// Every option that takes several values (`--add-dir`, `--disallowedTools`, `--allowedTools`) is
    /// followed by another option, and `--strict-mcp-config`, which takes none, is last: a first message after it is never read
    /// as one more directory, config or tool.
    public static func launchWords(model: String, effort: String?, runFolder: URL, projectPaths: [String],
                                   resuming conversation: String? = nil) -> [String] {
        let claude = AgentKind.claude.harness
        let head = conversation.map { claude.resumeWords(conversation: $0, model: model, reasoning: effort) }
            ?? claude.launchWords(model: model, reasoning: effort)
        // Claude otherwise reuses the conversation's first system prompt, ignoring a rewritten brief.
        return head
            + (conversation == nil ? [] : ["--system-prompt-snapshot", "off"])
            + ["--append-system-prompt-file", runFolder.appendingPathComponent(briefFile).path, "--tools", "Read,Grep,Glob,Bash"]
            + projectPaths.flatMap { ["--add-dir", $0] }
            + ["--settings", runFolder.appendingPathComponent(gateFile).path, "--disallowedTools"] + shellDenials
            + ["--mcp-config", runFolder.appendingPathComponent(mcpFile).path, "--allowedTools", "mcp__aiterm__*", "Bash",
               "--strict-mcp-config"]
    }

    /// The line the operator's window runs, every word shell-safe; a first message is read from
    /// `first-message.md` in the run folder, the window's working directory, as a big first prompt
    /// is read from `.aiterm/first-prompt.md` today. The line is typed into the person's own shell, so
    /// it reads the file with `command cat`: an alias or function of theirs named `cat` (one that pages,
    /// colours or numbers) would hand Claude its output instead of the message.
    public static func command(words: [String], firstMessage: Bool) -> String {
        (words.map(AgentCommand.shellWord) + (firstMessage ? ["\"$(command cat \(firstMessageFile))\""] : [])).joined(separator: " ")
    }

    /// `mcp.json`: one HTTP server, `aiterm` — so its tools are `mcp__aiterm__*` — at the daemon's
    /// `/operator` route, with the run's bearer token and the `X-AiTerm-Hook` header every route on
    /// the hook port requires (part B: without it the daemon answers 404).
    public static func mcpConfig(hookPort: Int, token: String) throws -> String {
        struct Server: Encodable { var type = "http"; var url: String; var headers: [String: String] }
        struct Config: Encodable { var mcpServers: [String: Server] }
        let config = Config(mcpServers: ["aiterm": Server(url: "http://127.0.0.1:\(hookPort)/operator",
                                                          headers: ["Authorization": "Bearer \(token)", "X-AiTerm-Hook": "1"])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(config), as: UTF8.self)
    }

    /// `gate.json`, the settings the Operator's launch is given: a PreToolUse hook on `Bash` that posts each
    /// command to the daemon's `/operator/gate` with the run's bearer token and the `X-AiTerm-Hook` header, and
    /// Claude's own cap on a command's output (`BASH_MAX_OUTPUT_LENGTH`, characters, with Claude's truncation
    /// note). The hook's timeout, 240 s, outlasts the 200 s the daemon waits for the gate's answer.
    public static func gateSettings(hookPort: Int, token: String) throws -> String {
        struct Hook: Encodable { var type = "http"; var url: String; var headers: [String: String]; var timeout = 240 }
        struct Matcher: Encodable { var matcher = "Bash"; var hooks: [Hook] }
        struct Settings: Encodable { var env: [String: String]; var hooks: [String: [Matcher]] }
        let hook = Hook(url: "http://127.0.0.1:\(hookPort)/operator/gate",
                        headers: ["Authorization": "Bearer \(token)", "X-AiTerm-Hook": "1"])
        let settings = Settings(env: ["BASH_MAX_OUTPUT_LENGTH": "16000"], hooks: ["PreToolUse": [Matcher(hooks: [hook])]])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(settings), as: UTF8.self)
    }

    /// A run's token: 32 random bytes as 64 hex digits, from the system's secure generator.
    public static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    /// The token a run folder holds, for a relaunch that keeps the registered one.
    public static func existingToken(in folder: URL) -> String? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(tokenFile), encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil ? token : nil
    }

    public struct Prepared: Equatable, Sendable {
        public var folder: URL
        public var command: String
        public var token: String
        public init(folder: URL, command: String, token: String) { self.folder = folder; self.command = command; self.token = token }
    }

    /// Writes the run folder — `brief.md`, `mcp.json`, `gate.json` and `token`, the three holding the token
    /// readable by you alone (0600, in a 0700 folder) — and returns the command to run in it.
    /// A fresh launch also writes the broadcast as `first-message.md`, the operator's first message:
    /// `firstMessage` when given (`freshStartMessage`), else `firstMessage(for:)`; `resuming` a
    /// conversation sends none. A command too long to type goes to `launch.sh` (`typed`).
    public static func prepare(run: OperatorRun, projects: [Project], hookPort: Int = AiTermPaths.hookPort,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser, claudeConfig: ClaudeConfig = ClaudeConfig(),
                               token: String = makeToken(),
                               resuming conversation: String? = nil, firstMessage message: String? = nil) throws -> Prepared {
        let folder = runFolder(run.id, home: home)
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try trustRunFolder(folder, home: home, claudeConfig: claudeConfig)
        try Data(brief(run: run, projects: projects).utf8)
            .write(to: folder.appendingPathComponent(briefFile), options: .atomic)
        try writePrivate(Data(try mcpConfig(hookPort: hookPort, token: token).utf8), to: folder.appendingPathComponent(mcpFile))
        // On a resume too: a reopened Operator gets the gate with its shell.
        try writePrivate(Data(try gateSettings(hookPort: hookPort, token: token).utf8), to: folder.appendingPathComponent(gateFile))
        // Exactly the 64 hex digits: the daemon reads the file back after a restart.
        try writePrivate(Data(token.utf8), to: folder.appendingPathComponent(tokenFile))
        let first = conversation == nil && !run.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if first {
            try Data((message ?? firstMessage(for: run)).utf8).write(to: folder.appendingPathComponent(firstMessageFile), options: .atomic)
        }
        let words = launchWords(model: run.profile.model, effort: run.profile.reasoning, runFolder: folder,
                                projectPaths: projects.map(\.path), resuming: conversation)
        return Prepared(folder: folder, command: try typed(command(words: words, firstMessage: first), in: folder), token: token)
    }

    /// Each broadcast runs in a new directory AiTerm created, outside the person's repositories.
    /// Record trust for that exact folder before Claude opens, without changing tool permissions.
    /// Claude's global-state writer uses a `.lock` directory around its read/merge/atomic write.
    /// Join that lock briefly; never take it from another writer or replace unreadable state.
    private static func trustRunFolder(_ folder: URL, home: URL, claudeConfig: ClaudeConfig) throws {
        let file = UserConfigFile(home: home, url: claudeConfig.globalJSON(home: home))
        let manager = FileManager.default, lock = file.url.appendingPathExtension("lock")
        // Foundation strips a leading `/private`; Claude keys trust on the physical working directory.
        guard let physical = realpath(folder.path, nil) else { throw POSIXError(.ENOENT) }
        defer { free(physical) }
        let path = String(cString: physical)
        func readState() throws -> [String: JSONValue] {
            switch file.read() {
            case .missing: return [:]
            case .refused(let reason): throw file.refusal(reason)
            case .present(let bytes):
                guard let object = (try? JSONDecoder().decode(JSONValue.self, from: bytes))?.objectValue else {
                    throw file.refusal("is not a JSON object")
                }
                return object
            }
        }
        if try readState()["projects"]?[path]?["hasTrustDialogAccepted"] == true { return }
        try manager.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var acquired = false
        for _ in 0..<40 {
            if mkdir(lock.path, 0o700) == 0 { acquired = true; break }
            let code = errno
            guard code == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard acquired else { throw file.refusal("is busy in another Claude session. Try starting the broadcast again") }
        defer { rmdir(lock.path) }

        // Re-read under the lock: another session may have saved since the fast-path read.
        var state = try readState()
        func object(_ value: JSONValue?, named key: String) throws -> [String: JSONValue] {
            guard let value else { return [:] }
            guard let object = value.objectValue else { throw file.refusal("sets \(key) in a form AiTerm cannot merge") }
            return object
        }
        var projects = try object(state["projects"], named: "projects")
        var project = try object(projects[path], named: "the Operator's project")
        guard project["hasTrustDialogAccepted"] != true else { return }
        project["hasTrustDialogAccepted"] = true
        projects[path] = .object(project)
        state["projects"] = .object(projects)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(JSONValue.object(state))
        try file.backUp()
        try writePrivate(bytes, to: file.target)
    }

    /// What the Operator's window has typed: `line` itself, or, past `AgentCommand.inlineLimit` (many
    /// projects, each its `--add-dir`), a line that reads it from `launch.sh` in the run folder, as a
    /// task's long first prompt is read from `.aiterm/first-prompt.md`: a terminal still in canonical
    /// mode keeps only 1024 bytes of a line. The file is readable by you alone, as the token is: it runs in your
    /// shell. A launch short enough to type removes an earlier one's file.
    static func typed(_ line: String, in folder: URL) throws -> String {
        let file = folder.appendingPathComponent(launchFile)
        guard line.utf8.count > AgentCommand.inlineLimit else {
            try? FileManager.default.removeItem(at: file)
            return line
        }
        try writePrivate(Data(line.utf8), to: file)
        return "eval \"$(command cat \(launchFile))\""
    }

    /// The first message has a fixed header so a prompt starting with a bullet is not read as a CLI option.
    /// Append the per-task review and optional broadcast goal.
    static func firstMessage(for run: OperatorRun) -> String {
        var text = "Your broadcast:\n\n" + run.prompt
        if let review = said(run.taskSettings.review) { text += "\n\nEach task is reviewed with: " + review }
        if let goal = said(run.goal?.text) { text += "\n\nGoal: " + goal }
        return text
    }

    /// A new Operator session for a broadcast under way (Start Fresh, or a reopening with no conversation
    /// to resume): the broadcast as `firstMessage(for:)` says it, then where it stands as `run_status`
    /// shows it (`status`, its JSON) and the decisions logged so far, so it picks the work up rather
    /// than plans it again.
    public static func freshStartMessage(for run: OperatorRun, status: String) -> String {
        var text = firstMessage(for: run)
        text += "\n\nThis is a new session of a broadcast already under way: its earlier conversation can’t be resumed. "
            + "Where it stands, as run_status shows it now:\n\n" + status
        let decisions = run.decisions.map { "- " + $0.text + ($0.why.map { " Why: " + $0 } ?? "") }
        text += decisions.isEmpty ? "\n\nNo decisions are logged yet." : "\n\nYour decisions so far:\n" + decisions.joined(separator: "\n")
        return text + "\n\nCall run_status, then carry on from there."
    }

    /// `text` trimmed, or nil when nothing is said: the one rule for what a person typed.
    public static func said(_ text: String?) -> String? {
        text.said
    }

    /// Writes `data` so it is never readable by anyone else, even for a moment: a file made 0600
    /// while still empty, filled, then renamed over `url`.
    static func writePrivate(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path]) }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
