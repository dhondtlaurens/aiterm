// app/Sources/AiTermCore/Hooks/HookInstaller.swift
import Foundation

/// What AiTerm merges into Claude Code's `settings.json` and Codex's `config.toml`, and how it
/// recognises its own entries there. The files themselves are read and written by `ClaudeDriver`
/// and `CodexDriver`; launch asks only whether Claude Code still runs the usage shim.
public enum HookInstaller {
    static let claudeEvents = ["SessionStart", "PostModelSwitch", "UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop", "Notification", "PermissionRequest"]
    static let codexEvents = ["SessionStart", "UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop", "PermissionRequest"]
    /// Events AiTerm used to install and no longer does. `PreToolUse` was a *synchronous* Bash hook
    /// for a cleanup interception the daemon has since dropped, so every Bash tool call waited on a
    /// round trip that answered nothing. A merge removes AiTerm's own entries from these and leaves
    /// anyone else's in place.
    static let retiredClaudeEvents = ["PreToolUse"]
    static let marker = "_aiterm"

    static func isOwned(_ hook: [String: Any]) -> Bool { hook[marker] as? Bool == true }
    static func holdsOwnedHook(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains(where: isOwned) == true
    }

    private static func claudeHook(hookURL: String) -> [String: Any] {
        ["type": "http", "url": hookURL, "headers": ["X-AiTerm-Hook": "1"],
         "timeout": 3, "async": true, marker: true]
    }

    private static func claudeEntry(hookURL: String) -> [String: Any] {
        ["matcher": "", "hooks": [claudeHook(hookURL: hookURL)]]
    }

    /// Our shim, recognised by filename as well as by exact path (T9-1 fix 2): a moved app bundle
    /// leaves the old path in `settings.json`, and that command is still ours, not a foreign tool's.
    static func isOurShim(_ command: String, shimPath: String) -> Bool {
        command == shimPath || URL(fileURLWithPath: command).lastPathComponent == URL(fileURLWithPath: shimPath).lastPathComponent
    }
    static let codexBegin = "# >>> aiterm hooks >>>", codexEnd = "# <<< aiterm hooks <<<"

    /// `settings.json` is the user's file, so what we write changes only what we merge: no `\/` for
    /// every `/`, and sorted keys so a rerun produces the same bytes.
    static let jsonOptions: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    /// `settings.json` as an object: no bytes, or none at all, is "no settings yet". Anything else
    /// that is not a JSON object — malformed JSON, or an array — is `nil` (T9-1 fix 1), and must
    /// never be merged as if empty: that would replace the user's settings with our entries alone.
    static func claudeSettings(_ json: Data?) -> [String: Any]? {
        guard let json, !json.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
    }

    static func mergeClaudeSettings(_ json: Data?, hookURL: String, shimPath: String) throws -> (Data, originalStatusLine: [String: Any]?) {
        guard var obj = claudeSettings(json) else {
            throw HarnessDriverError.refused(path: "~/" + ClaudeDriver.settingsPath, reason: "is not a JSON object")
        }
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        for event in retiredClaudeEvents {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            let kept = entries.compactMap { entry -> [String: Any]? in
                guard let installed = entry["hooks"] as? [[String: Any]], installed.contains(where: isOwned) else { return entry }
                let foreign = installed.filter { !isOwned($0) }
                guard !foreign.isEmpty else { return nil }
                var entry = entry; entry["hooks"] = foreign; return entry
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        for event in claudeEvents {
            var inserted = false
            var entries: [[String: Any]] = []
            for entry in hooks[event] as? [[String: Any]] ?? [] {
                guard let installed = entry["hooks"] as? [[String: Any]], installed.contains(where: isOwned) else {
                    entries.append(entry); continue
                }
                // Replace our first occurrence in place; keep foreign hooks and their matcher.
                if !inserted {
                    entries.append(claudeEntry(hookURL: hookURL))
                    inserted = true
                }
                let foreign = installed.filter { !isOwned($0) }
                if !foreign.isEmpty {
                    var kept = entry; kept["hooks"] = foreign; entries.append(kept)
                }
            }
            if !inserted { entries.append(claudeEntry(hookURL: hookURL)) }
            hooks[event] = entries
        }
        obj["hooks"] = hooks
        var original: [String: Any]? = nil
        let current = obj["statusLine"] as? [String: Any]
        let currentCommand = current?["command"] as? String
        // A moved bundle's old shim is repointed to `shimPath` but never saved as a "foreign"
        // original — saving it would make the shim wrap itself and recurse forever.
        if !(currentCommand.map { isOurShim($0, shimPath: shimPath) } ?? false) {
            original = current
        }
        if currentCommand != shimPath {
            obj["statusLine"] = ["type": "command", "command": shimPath, "padding": current?["padding"] ?? 0]
        }
        return (try JSONSerialization.data(withJSONObject: obj, options: jsonOptions), original)
    }

    private static func statusLineCommand(_ settings: [String: Any]) -> String? {
        (settings["statusLine"] as? [String: Any])?["command"] as? String
    }

    /// Is AiTerm's shim still Claude Code's status line? Claude Code hands `rate_limits` to the
    /// status line command and to nothing else, so this one entry is the whole Claude usage feed —
    /// and it lives in a file the user, Claude Code's own `/statusline`, and every other tool that
    /// edits `settings.json` can rewrite. `installHooksOnFirstRun`'s one-shot flag records that we
    /// once wrote it, not that it is still there, so the answer has to be read off the file itself.
    /// Matched by filename, like `mergeClaudeSettings`: a moved bundle is still our shim.
    /// `isRunnable` is the second half of the question: a command Claude Code cannot exec is not
    /// an installed status line, however right its name looks. A translocated bundle, a build
    /// deleted with its worktree and an app dragged to the Trash all leave the filename matching
    /// and the feed dead, and the footer has to say so rather than report health.
    static func claudeStatusLineIsInstalled(_ json: Data?, shimPath: String,
                                            isRunnable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Bool {
        guard let json, let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let command = statusLineCommand(obj) else { return false }
        return isOurShim(command, shimPath: shimPath) && isRunnable(command)
    }

    public static func claudeStatusLineIsInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser, shimPath: String) -> Bool {
        claudeStatusLineIsInstalled(try? Data(contentsOf: home.appendingPathComponent(ClaudeDriver.settingsPath)), shimPath: shimPath)
    }

    /// Codex rewrites TOML tables independently of comments, so markers alone cannot delimit
    /// ownership. Reconcile the actual hook tables, including entries moved outside the markers.
    static func mergeCodexConfig(_ toml: String?, hookURL: String) -> String {
        CodexHookConfig.merge(toml ?? "", hookURL: hookURL)
    }

    /// The canonical driver tables, with markers for humans reading the file.
    static func codexBlock(hookURL: String) -> String {
        var block = codexBegin + "\n"
        // Codex starts command hooks in the session cwd. A merge workflow can remove that cwd
        // before Stop fires, making curl fail to spawn with ENOENT. Keep the final lifecycle event
        // on a persistent MCP connection instead; the other events remain lightweight async posts.
        block += "[mcp_servers.aiterm_hooks]\n"
        block += "url = \"\(hookURL)/mcp\"\nenabled = true\nrequired = false\nenabled_tools = [\"post_codex_hook\"]\n\n"
        block += "[mcp_servers.aiterm_hooks.http_headers]\nX-AiTerm-Hook = \"1\"\n\n"
        block += "[mcp_servers.aiterm_hooks.env_http_headers]\nX-AiTerm-iTerm-Session = \"ITERM_SESSION_ID\"\n\n"
        for event in codexEvents {
            block += "[[hooks.\(event)]]\nmatcher = \"\"\n[[hooks.\(event).hooks]]\n"
            if event == "Stop" {
                block += "type = \"mcp_tool\"\nserver = \"aiterm_hooks\"\ntool = \"post_codex_hook\"\n"
                block += "input = { session_id = \"${session_id}\", cwd = \"${cwd}\", hook_event_name = \"${hook_event_name}\", model = \"${model}\", turn_id = \"${turn_id}\", stop_hook_active = \"${stop_hook_active}\", last_assistant_message = \"${last_assistant_message}\" }\n"
                block += "timeout = 5\n\n"
            } else {
                block += "type = \"command\"\ncommand = 'curl -s -m 2 -X POST -H \"Content-Type: application/json\" -H \"X-AiTerm-Hook: 1\" -H \"X-AiTerm-iTerm-Session: $ITERM_SESSION_ID\" -H \"Expect:\" --data-binary @- \(hookURL)/hook/codex'\ntimeout = 5\nasync = true\n\n"
            }
        }
        return block + codexEnd
    }

    /// Exactly the hooks and status line a merge writes, and nothing retired left behind.
    static func claudeHooksAreInstalled(_ settings: [String: Any], daemonPort: Int, shimPath: String) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any],
              let command = statusLineCommand(settings), isOurShim(command, shimPath: shimPath) else { return false }
        let hookURL = "http://127.0.0.1:\(daemonPort)/hook/claude"
        // A retired hook still in place is an outdated install: repairing it is what removes it.
        let retiredRemain = retiredClaudeEvents.contains { (hooks[$0] as? [[String: Any]])?.contains(where: holdsOwnedHook) == true }
        return !retiredRemain && claudeEvents.allSatisfy { event in
            let ownedEntries = (hooks[event] as? [[String: Any]] ?? []).filter(holdsOwnedHook)
            guard ownedEntries.count == 1, let entry = ownedEntries.first,
                  entry["matcher"] as? String == "" else { return false }
            let owned = (entry["hooks"] as? [[String: Any]] ?? []).filter(isOwned)
            guard owned.count == 1, let hook = owned.first else { return false }
            return (hook as NSDictionary) == (claudeHook(hookURL: hookURL) as NSDictionary)
        }
    }

    /// Whether a settings object contains any AiTerm-owned hook or status-line entry. This is
    /// deliberately broader than `claudeHooksAreInstalled`: an old URL, a moved shim, or an
    /// incomplete owned hook set is still ours and can be repaired safely.
    static func claudeHooksAreOwned(_ settings: [String: Any], shimPath: String) -> Bool {
        if let command = statusLineCommand(settings), isOurShim(command, shimPath: shimPath) { return true }
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { ($0 as? [[String: Any]])?.contains(where: holdsOwnedHook) == true }
    }

    static func codexHooksAreInstalled(_ text: String, daemonPort: Int) -> Bool {
        mergeCodexConfig(text, hookURL: "http://127.0.0.1:\(daemonPort)") == text
    }

    /// Recognise owned tables even after Codex moves them away from the marker comments.
    static func codexHooksAreOwned(_ text: String) -> Bool {
        CodexHookConfig.hasOwnedEntries(text)
    }

    /// Launch's half of the status-line upgrade: an install from before the shim read plain text
    /// kept only the JSON record of the user's own status line, which the shim no longer parses,
    /// and nothing else reports that install as out of date. Writing its command out here keeps
    /// that status line showing without waiting for Settings' Install or Repair.
    public static func migrateOriginalStatusLine(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let support = home.appendingPathComponent("Library/Application Support/AiTerm")
        try migrateOriginalCommand(from: support.appendingPathComponent("statusline-original.json"),
                                   to: support.appendingPathComponent("statusline-original.cmd"))
    }

    /// Writes the command of an old JSON record out as the plain-text file the shim reads, once:
    /// a command file already there is the record, whatever the JSON says.
    static func migrateOriginalCommand(from originalURL: URL, to commandURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: commandURL.path), let data = try? Data(contentsOf: originalURL),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        try saveOriginalCommand(saved["command"] as? String, to: commandURL)
    }

    /// Claude Code runs the shim on every status-line tick, so the user's original command is kept
    /// as plain text the shim reads without starting an interpreter. No command, no file: the shim
    /// then prints nothing, as it does when there was never an original.
    static func saveOriginalCommand(_ command: String?, to url: URL) throws {
        if let command, !command.isEmpty { try Data(command.utf8).write(to: url, options: .atomic) }
        else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// Whether a merge changed what the file says, not how it is written: another tool's key order,
    /// whitespace, escaped slashes or a float's digits are no reason to rewrite the user's file.
    static func sameSettings(_ original: Data?, _ merged: Data) -> Bool {
        guard let original, let before = try? JSONSerialization.jsonObject(with: original),
              let after = try? JSONSerialization.jsonObject(with: merged),
              let a = try? JSONSerialization.data(withJSONObject: before, options: jsonOptions),
              let b = try? JSONSerialization.data(withJSONObject: after, options: jsonOptions) else { return false }
        return a == b
    }
}
