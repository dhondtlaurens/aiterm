import Testing
import Foundation
@testable import AiTermCore

@Suite struct HookConfigTests {
    let emdashSettings = """
    {"statusLine": {"type": "command", "command": "/Users/me/.claude/statusline/statusline.py", "padding": 1},
     "hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "/Users/me/.emdash/hook.sh", "_emdash": true}]}]},
     "model": "opus"}
    """

    @Test func testClaudeMergeKeepsForeignEntriesWrapsStatusLineAndIsIdempotent() throws {
        let url = "http://127.0.0.1:47821/hook/claude"
        let (once, original) = try ClaudeSettings.merge(Data(emdashSettings.utf8), hookURL: url, shimPath: "/Applications/AiTerm.app/shim.sh")
        let obj = try JSONSerialization.jsonObject(with: once) as! [String: Any]
        let hooks = obj["hooks"] as! [String: [[String: Any]]]
        #expect(hooks["Stop"]!.count == 2, "Emdash entry kept, ours added")
        #expect(Set(hooks.keys) == ["SessionStart", "PostModelSwitch", "UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop", "Notification", "PermissionRequest"])
        #expect(hooks.values.allSatisfy { $0.allSatisfy { entry in
            (entry["hooks"] as! [[String: Any]]).allSatisfy { $0["_aiterm"] == nil || $0["async"] as? Bool == true }
        } }, "every AiTerm hook is telemetry, so none may hold the agent up")
        #expect(((hooks["Notification"]![0]["hooks"] as! [[String: Any]])[0]["url"] as? String) == url)
        #expect((((hooks["Notification"]![0]["hooks"] as! [[String: Any]])[0]["headers"] as! [String: String])["X-AiTerm-Hook"]) == "1")
        #expect((obj["statusLine"] as! [String: Any])["command"] as? String == "/Applications/AiTerm.app/shim.sh")
        #expect((obj["statusLine"] as! [String: Any])["padding"] as? Int == 1)
        #expect(original?["command"] as? String == "/Users/me/.claude/statusline/statusline.py")
        #expect(obj["model"] as? String == "opus")
        let (twice, originalAgain) = try ClaudeSettings.merge(once, hookURL: url, shimPath: "/Applications/AiTerm.app/shim.sh")
        #expect(try JSONSerialization.jsonObject(with: twice) as! NSDictionary == obj as NSDictionary)
        #expect(originalAgain == nil, "shim already installed: nothing to save")
    }

    @Test func testClaudeMergeFromEmptyFile() throws {
        let (data, original) = try ClaudeSettings.merge(nil, hookURL: "u", shimPath: "s")
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((obj["hooks"] as! [String: Any]).count == 8)
        #expect(original == nil)
    }

    @Test func testTelemetryReinstallPreservesACustomDisplayButDoesNotReviveARemovedOne() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"statusLine":{"type":"command","command":"my-statusline"}}"#.utf8).write(to: settings)
        let shim = "/Applications/AiTerm.app/claude-statusline-shim.sh"
        try ClaudeDriver(home: home, daemonPort: 47821, shimPath: shim).install()
        let original = home.appendingPathComponent("Library/Application Support/AiTerm/statusline-original.json")
        let command = home.appendingPathComponent("Library/Application Support/AiTerm/statusline-original.cmd")
        let saved = try Data(contentsOf: original)
        #expect(try String(contentsOf: command, encoding: .utf8) == "my-statusline", "the shim reads the command as plain text")
        try ClaudeDriver(home: home, daemonPort: 47821, shimPath: shim).install()
        #expect(try Data(contentsOf: original) == saved)
        #expect(try String(contentsOf: command, encoding: .utf8) == "my-statusline")
        try Data("{}".utf8).write(to: settings)
        try ClaudeDriver(home: home, daemonPort: 47821, shimPath: shim).install()
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: command.path))
        #expect(ClaudeSettings.statusLineIsInstalled(try Data(contentsOf: settings), shimPath: shim, isRunnable: { _ in true }))
    }

    /// AiTerm once installed `PreToolUse` as a synchronous Bash hook. A merge takes out only our
    /// own entry — a foreign hook sharing the entry or the event stays — and until that repair has
    /// run, the install reads as outdated rather than current.
    @Test func testRetiredPreToolUseHookIsRemovedButForeignOnesStay() throws {
        let ours: [String: Any] = ["type": "http", "url": "http://127.0.0.1:47821/hook/claude", "_aiterm": true, "timeout": 3]
        let foreign: [String: Any] = ["type": "command", "command": "/usr/local/bin/guard.sh"]
        let old = try JSONSerialization.data(withJSONObject: ["hooks": ["PreToolUse": [
            ["matcher": "Bash", "hooks": [ours]],
            ["matcher": "Bash", "hooks": [ours, foreign]],
        ]]])
        let (merged, _) = try ClaudeSettings.merge(old, hookURL: "http://127.0.0.1:47821/hook/claude", shimPath: "s")
        let hooks = (try JSONSerialization.jsonObject(with: merged) as! [String: Any])["hooks"] as! [String: Any]
        let preTool = hooks["PreToolUse"] as! [[String: Any]]
        #expect(preTool.count == 1)
        #expect((preTool[0]["hooks"] as! [[String: Any]]).map { $0["command"] as? String } == ["/usr/local/bin/guard.sh"])

        let onlyOurs = try JSONSerialization.data(withJSONObject: ["hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [ours]]]]])
        let (cleaned, _) = try ClaudeSettings.merge(onlyOurs, hookURL: "u", shimPath: "s")
        #expect(((try JSONSerialization.jsonObject(with: cleaned) as! [String: Any])["hooks"] as! [String: Any])["PreToolUse"] == nil)

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let shim = "/Applications/AiTerm.app/claude-statusline-shim.sh"
        try ClaudeDriver(home: home, daemonPort: 47821, shimPath: shim).install()
        #expect(ClaudeDriver(home: home, daemonPort: 47821, shimPath: shim).state == .current)
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        var withRetired = obj["hooks"] as! [String: Any]
        withRetired["PreToolUse"] = [["matcher": "Bash", "hooks": [ours]]]
        obj["hooks"] = withRetired
        try JSONSerialization.data(withJSONObject: obj).write(to: settings)
        #expect(ClaudeDriver(home: home, daemonPort: 47821, shimPath: shim).state != .current)
        try ClaudeDriver(home: home, daemonPort: 47821, shimPath: shim).install()
        #expect(ClaudeDriver(home: home, daemonPort: 47821, shimPath: shim).state == .current)
    }

    @Test func testLegacyOwnedHeaderIsRenamedWithoutDuplicatingHooks() throws {
        let old = Data(#"{"hooks":{"Stop":[{"hooks":[{"_aiterm":true,"type":"http","headers":{"X-AIterm-Hook":"1"}}]},{"hooks":[{"type":"http","headers":{"X-AIterm-Hook":"foreign"}}]}]}}"#.utf8)
        let (merged, _) = try ClaudeSettings.merge(old, hookURL: "u", shimPath: "s")
        let obj = try JSONSerialization.jsonObject(with: merged) as! [String: Any]
        let stops = (obj["hooks"] as! [String: [[String: Any]]])["Stop"]!
        #expect(stops.count == 2)
        let ours = (stops[0]["hooks"] as! [[String: Any]])[0]["headers"] as! [String: String]
        let foreign = (stops[1]["hooks"] as! [[String: Any]])[0]["headers"] as! [String: String]
        #expect(ours == ["X-AiTerm-Hook": "1"])
        #expect(foreign == ["X-AIterm-Hook": "foreign"])
    }

    @Test func testCodexMergeAppendsOnceAndReplacesOwnBlock() {
        let base = "model = \"gpt-5.6\"\n\n[[hooks.SessionStart]]\nmatcher = \"^startup$\"\n[[hooks.SessionStart.hooks]]\ntype = \"command\"\ncommand = 'python3 ~/.codex/hooks/emdash.py'\n"
        let once = CodexHookConfig.merge(base, hookURL: "http://127.0.0.1:47821")
        #expect(once.hasPrefix(base))
        #expect(once.components(separatedBy: "# >>> aiterm hooks >>>").count == 2)
        #expect(once.contains("[[hooks.PermissionRequest]]") && once.contains("/hook/codex"))
        #expect(once.contains("[[hooks.SubagentStart]]") && once.contains("[[hooks.SubagentStop]]"))
        #expect(!once.contains("PreToolUse"), "the retired synchronous Bash hook is not installed")
        #expect(once.contains("X-AiTerm-Hook: 1") && once.contains("Expect:"))
        #expect(once.contains("X-AiTerm-iTerm-Session: $ITERM_SESSION_ID"))
        #expect(once.contains("[mcp_servers.aiterm_hooks]"))
        #expect(once.contains("url = \"http://127.0.0.1:47821/mcp\""))
        #expect(once.contains("X-AiTerm-iTerm-Session = \"ITERM_SESSION_ID\""))
        let stop = once.components(separatedBy: "[[hooks.Stop]]")[1]
        #expect(stop.contains("type = \"mcp_tool\""))
        #expect(stop.contains("tool = \"post_codex_hook\""))
        #expect(stop.contains("hook_event_name = \"${hook_event_name}\""))
        let twice = CodexHookConfig.merge(once, hookURL: "http://127.0.0.1:9999")
        #expect(twice.components(separatedBy: "# >>> aiterm hooks >>>").count == 2)
        #expect(twice.contains(":9999/hook/codex") && twice.contains(":9999/mcp") && !twice.contains(":47821"))
        #expect(twice.contains("emdash.py"))
    }


    @Test func claudeRepairReplacesStaleAndDuplicateHooksButKeepsMixedForeignHooks() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        try ClaudeDriver(home: home, daemonPort: 47821, shimPath: "s").install()
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        var hooks = obj["hooks"] as! [String: [[String: Any]]]
        let current = hooks["Stop"]![0]
        let stale: [String: Any] = ["_aiterm": true, "type": "http", "url": "http://127.0.0.1:1/hook/claude", "async": false]
        let foreign: [String: Any] = ["type": "command", "command": "keep-me"]
        hooks["Stop"] = [current, ["matcher": "Bash", "hooks": [stale, foreign]], current]
        obj["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: obj).write(to: settings)
        #expect(ClaudeDriver(home: home, daemonPort: 47821, shimPath: "s").state != .current)
        try ClaudeDriver(home: home, daemonPort: 9999, shimPath: "s").install()
        let repaired = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        let stops = (repaired["hooks"] as! [String: [[String: Any]]])["Stop"]!
        let owned = stops.flatMap { $0["hooks"] as! [[String: Any]] }.filter { $0["_aiterm"] as? Bool == true }
        #expect(owned.count == 1)
        #expect(owned.first?["url"] as? String == "http://127.0.0.1:9999/hook/claude")
        #expect(owned.first?["async"] as? Bool == true)
        let mixed = try #require(stops.first { $0["matcher"] as? String == "Bash" })
        #expect((mixed["hooks"] as! [[String: Any]]) as NSArray == [foreign] as NSArray)
        #expect(ClaudeDriver(home: home, daemonPort: 9999, shimPath: "s").state == .current)
    }

    @Test func codexRepairFindsMovedHooksAndPreservesApprovalRecords() throws {
        let moved = """
        [[hooks.SessionStart]]
        matcher = ""
        [[hooks.SessionStart.hooks]]
        type = "command"
        command = 'curl -s -m 2 -X POST -H "X-AiTerm-Hook: 1" --data-binary @- http://127.0.0.1:1/hook/codex'
        [[hooks.SessionStart.hooks]]
        type = "command"
        command = 'keep-me'
        # >>> aiterm hooks >>>
        [mcp_servers.aiterm_hooks]
        url = "http://127.0.0.1:1/mcp"
        [hooks.state."config:session_start:0:1"]
        trusted_hash = "sha256:keep-me"
        [[hooks.Stop]]
        [[hooks.Stop.hooks]]
        type = "mcp_tool"
        server = "aiterm_hooks"
        tool = "post_codex_hook"
        # <<< aiterm hooks <<<
        """
        let result = CodexHookConfig.merge(moved, hookURL: "http://127.0.0.1:47821")
        #expect(!result.contains(":1/hook/codex"))
        #expect(result.contains("command = 'keep-me'"))
        #expect(result.contains("[hooks.state.\"config:session_start:0:1\"]\ntrusted_hash = \"sha256:keep-me\""))
        #expect(result.components(separatedBy: "[[hooks.SessionStart]]").count - 1 == 2)
        #expect(result.components(separatedBy: "[[hooks.Stop]]").count - 1 == 1)
        #expect(CodexHookConfig.merge(result, hookURL: "http://127.0.0.1:47821") == result)
    }

    @Test func codexRepairRemovesDuplicateBlocksAndHooksWithMissingMarkers() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        let block = CodexHookConfig.merge(nil, hookURL: "http://127.0.0.1:47821")
        for input in [block + block, block.replacingOccurrences(of: CodexHookConfig.end, with: ""),
                      block.replacingOccurrences(of: CodexHookConfig.begin, with: "")] {
            try input.write(to: config, atomically: true, encoding: .utf8)
            #expect(CodexDriver(home: home, daemonPort: 47821).state != .current)
            try CodexDriver(home: home, daemonPort: 47821).install()
            let result = try String(contentsOf: config, encoding: .utf8)
            #expect(result.components(separatedBy: "[[hooks.SessionStart]]").count - 1 == 1)
            #expect(result.components(separatedBy: "[[hooks.Stop]]").count - 1 == 1)
            #expect(result.components(separatedBy: "[mcp_servers.aiterm_hooks]").count - 1 == 1)
            #expect(CodexDriver(home: home, daemonPort: 47821).state == .current)
        }
    }

    @Test func codexRepairDoesNotInterpretStringsOrCommentsAsOwnedHooks() {
        let foreign = """
        description = '''
        # >>> aiterm hooks >>>
        [[hooks.Stop.hooks]]
        type = "mcp_tool"
        server = "aiterm_hooks"
        tool = "post_codex_hook"
        # <<< aiterm hooks <<<
        '''
        [[hooks.Stop]]
        [[hooks.Stop.hooks]]
        type = "command"
        command = 'echo aiterm'
        # command = 'curl -H "X-AiTerm-Hook: 1" http://127.0.0.1:47821/hook/codex'
        [profiles.keep]
        model = "keep-me"
        """ + "\n"
        let result = CodexHookConfig.merge(foreign, hookURL: "http://127.0.0.1:47821")
        #expect(result.hasPrefix(foreign))
        #expect(CodexHookConfig.merge(result, hookURL: "http://127.0.0.1:47821") == result)
    }

    @Test func codexRepairAcceptsCRLFAndMultilineStringsEndingInQuotes() {
        let block = CodexHookConfig.merge(nil, hookURL: "http://127.0.0.1:1")
        for input in [block.replacingOccurrences(of: "\n", with: "\r\n"),
                      "description = \"\"\"hello\"\"\"\"\n" + block] {
            let result = CodexHookConfig.merge(input, hookURL: "http://127.0.0.1:47821")
            #expect(!result.contains(":1/mcp"))
            #expect(result.components(separatedBy: "[[hooks.Stop]]").count - 1 == 1)
            #expect(CodexHookConfig.merge(result, hookURL: "http://127.0.0.1:47821") == result)
        }
    }

    @Test func codexRepairKeepsForeignChildrenAfterInterveningTables() {
        let input = """
        [[hooks.Stop]]
        matcher = "keep-matcher"
        [[hooks.Stop.hooks]]
        type = "mcp_tool"
        server = "aiterm_hooks"
        tool = "post_codex_hook"
        [hooks.Stop.hooks.input]
        session_id = "old-input"
        # Keep this profile explanation.
        [profiles.fast]
        model = "keep-model"
        [[hooks.Stop.hooks]]
        type = "command"
        command = "keep-command"
        """
        let result = CodexHookConfig.merge(input, hookURL: "http://127.0.0.1:47821")
        #expect(result.contains("[[hooks.Stop]]\nmatcher = \"keep-matcher\""))
        #expect(result.contains("command = \"keep-command\""))
        #expect(result.contains("[profiles.fast]\nmodel = \"keep-model\""))
        #expect(result.contains("# Keep this profile explanation."))
        #expect(!result.contains("old-input"))
        #expect(result.components(separatedBy: "[[hooks.Stop]]").count - 1 == 2)
        #expect(CodexHookConfig.merge(result, hookURL: "http://127.0.0.1:47821") == result)
    }

    // MARK: - T9-1 fix 1: an unreadable/non-object settings.json must never be silently replaced

    @Test func testClaudeMergeThrowsOnUnparsableSettingsInsteadOfReplacingIt() {
        let malformedError = #expect(throws: (any Error).self) {
            _ = try ClaudeSettings.merge(Data("{nope".utf8), hookURL: "u", shimPath: "s")
        }
        #expect(malformedError is HarnessDriverError, "malformed JSON must raise a typed error, not fall back to an empty object")

        let nonObjectError = #expect(throws: (any Error).self) {
            _ = try ClaudeSettings.merge(Data("[]".utf8), hookURL: "u", shimPath: "s")
        }
        #expect(nonObjectError is HarnessDriverError, "a JSON array is not a settings object and must raise a typed error")
    }

    @Test func testClaudeMergeFromEmptyDataStillStartsEmpty() throws {
        let (data, original) = try ClaudeSettings.merge(Data(), hookURL: "u", shimPath: "s")
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((obj["hooks"] as! [String: Any]).count == ClaudeSettings.events.count, "empty (as opposed to malformed) settings data still merges from an empty object")
        #expect(original == nil)
    }

    // MARK: - T9-1 fix 2: a moved app bundle must not make the shim recurse into itself

    @Test func testClaudeMergeRepointsAMovedShimWithoutRecordingItAsAForeignOriginal() throws {
        let settingsWithOldShimPath = """
        {"statusLine": {"type": "command", "command": "/old/AIterm.app/Contents/Resources/claude-statusline-shim.sh", "padding": 2}}
        """
        let newShimPath = "/new/AiTerm.app/Contents/Resources/claude-statusline-shim.sh"
        let (data, original) = try ClaudeSettings.merge(Data(settingsWithOldShimPath.utf8), hookURL: "http://127.0.0.1:47821/hook/claude", shimPath: newShimPath)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((obj["statusLine"] as! [String: Any])["command"] as? String == newShimPath, "the moved bundle's shim path must be repointed to the new location")
        #expect((obj["statusLine"] as! [String: Any])["padding"] as? Int == 2, "padding from the old shim entry is preserved")
        #expect(original == nil, "the old shim path is recognised as ours by filename and must never be saved as a foreign original (that would make the shim recurse into itself)")
    }

    // MARK: - T9-1 fix 3: Codex marker handling must never trap and must never eat user content

    @Test func testCodexMergeHandlesEndMarkerBeforeBeginWithoutCrashingAndKeepsUserContent() {
        let corrupted = "keep-me = true\n" + CodexHookConfig.end + "\n" + CodexHookConfig.begin + "\n" + "trailing-line = true\n"
        let merged = CodexHookConfig.merge(corrupted, hookURL: "http://127.0.0.1:47821")
        #expect(merged.contains("keep-me = true"), "non-marker user content before the markers must survive")
        #expect(merged.contains("trailing-line = true"), "non-marker user content after the markers must survive")
        #expect(merged.components(separatedBy: CodexHookConfig.begin).count == 2, "exactly one well-formed block, not two")
        #expect(merged.components(separatedBy: CodexHookConfig.end).count == 2, "exactly one well-formed block, not two")
        #expect(merged.contains("[[hooks.PermissionRequest]]") && merged.contains("/hook/codex"))
    }

    @Test func testCodexMergeStripsOrphanBeginMarkerAndKeepsUserContent() {
        let corrupted = "keep-me = true\n" + CodexHookConfig.begin + "\n" + "trailing-line = true\n"
        let merged = CodexHookConfig.merge(corrupted, hookURL: "http://127.0.0.1:47821")
        #expect(merged.contains("keep-me = true"), "non-marker user content before the orphan marker must survive")
        #expect(merged.contains("trailing-line = true"), "non-marker user content after the orphan marker must survive")
        #expect(merged.components(separatedBy: CodexHookConfig.begin).count == 2, "exactly one well-formed block, not two")
        #expect(merged.components(separatedBy: CodexHookConfig.end).count == 2, "exactly one well-formed block, not two")
    }

    // MARK: - T9-1 fix 4: write statusline-original.json before settings.json so a crash in between can't lose it

    @Test func testInstallWritesOriginalStatusLineBeforeSettingsFileSurvivesASettingsWriteFailure() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-home-\(UUID().uuidString)")
        let claudeDir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        try Data("""
        {"statusLine": {"type": "command", "command": "/Users/me/.claude/statusline/statusline.py", "padding": 1}}
        """.utf8).write(to: settingsURL)
        // Make the .claude directory read-only so writing (and backing up) settings.json fails,
        // while Library/Application Support/AiTerm (a sibling tree) stays writable. If the
        // installer still writes statusline-original.json first, it survives the failed
        // settings.json write below; if it wrote settings.json first, the original would be lost.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: claudeDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeDir.path)
            try? FileManager.default.removeItem(at: home)
        }

        #expect(throws: (any Error).self) {
            try ClaudeDriver(home: home, daemonPort: 47821, shimPath: "/Applications/AiTerm.app/shim.sh").install()
        }

        let originalPath = home.appendingPathComponent("Library/Application Support/AiTerm/statusline-original.json")
        let savedOriginal = try JSONSerialization.jsonObject(with: try Data(contentsOf: originalPath)) as! [String: Any]
        #expect(savedOriginal["command"] as? String == "/Users/me/.claude/statusline/statusline.py", "the original status line must have been saved before the (failing) settings.json write")
    }

    /// The shim is the only channel Claude usage can arrive through — Claude Code hands out
    /// `rate_limits` to the status line command and nowhere else — and anything may take it back
    /// out of `settings.json` (a `/statusline` change, another tool, the user). A one-shot
    /// "installed" flag therefore cannot be trusted; every launch has to look at the file.
    @Test func testAMissingOrForeignStatusLineIsDetected() {
        let shim = "/Applications/AiTerm.app/Contents/Resources/hooks/claude-statusline-shim.sh"
        let ours = Data(#"{"statusLine":{"type":"command","command":"\#(shim)"}}"#.utf8)
        #expect(ClaudeSettings.statusLineIsInstalled(ours, shimPath: shim, isRunnable: { _ in true }))
        #expect(!ClaudeSettings.statusLineIsInstalled(Data(#"{"hooks":{}}"#.utf8), shimPath: shim),
                "statusLine deleted outright — the usage feed is dead and the footer must say so")
        #expect(!ClaudeSettings.statusLineIsInstalled(Data(#"{"statusLine":{"type":"command","command":"/Users/me/.claude/statusline/statusline.py"}}"#.utf8), shimPath: shim),
                "someone else's status line is not ours")
        #expect(!ClaudeSettings.statusLineIsInstalled(nil, shimPath: shim))
        #expect(!ClaudeSettings.statusLineIsInstalled(Data("not json".utf8), shimPath: shim))
    }

    /// The bundle can move (a rebuild into another directory, a drag to /Applications) without the
    /// shim ceasing to be ours — `mergeClaudeSettings` already repoints it by filename rather than
    /// treating it as a foreign original, and the launch check has to agree, or every move would
    /// report the feed as broken. What it must not agree with is a path nothing answers at.
    @Test func testTheShimIsStillOursAfterTheBundleMovesButNotAfterItVanishes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-shim-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let moved = dir.appendingPathComponent("claude-statusline-shim.sh")
        try "#!/bin/zsh\nexit 0\n".write(to: moved, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: moved.path)
        let settings = Data(#"{"statusLine":{"type":"command","command":"\#(moved.path)"}}"#.utf8)
        let shim = "/Applications/AiTerm.app/Contents/Resources/hooks/claude-statusline-shim.sh"
        #expect(ClaudeSettings.statusLineIsInstalled(settings, shimPath: shim))
        try FileManager.default.removeItem(at: moved)
        #expect(!ClaudeSettings.statusLineIsInstalled(settings, shimPath: shim),
                "a command Claude Code can only fail to exec is not an installed status line")
    }

    /// A user's machine: macOS ran the quarantined bundle from an AppTranslocation mount,
    /// the installer wrote that ephemeral path into settings.json, and the mount died with the
    /// app. Claude Code got exit 127 on every tick while the footer reported the feed as healthy,
    /// because the filename still matched.
    @Test func testATranslocatedStatusLineCommandIsReportedAsDisconnected() {
        let gone = "/private/var/folders/t8/251d/T/AppTranslocation/729DBBB2-661E/d/AiTerm 2.app/Contents/Resources/hooks/claude-statusline-shim.sh"
        #expect(!ClaudeSettings.statusLineIsInstalled(
            Data(#"{"statusLine":{"type":"command","command":"\#(gone)"}}"#.utf8),
            shimPath: "/Applications/AiTerm.app/Contents/Resources/hooks/claude-statusline-shim.sh"))
    }

    @Test func testATranslocatedBundleIsRecognisedByItsPath() {
        #expect(BundleLocation.isTranslocated("/private/var/folders/t8/251d/T/AppTranslocation/729DBBB2-661E/d/AiTerm 2.app/Contents/Resources"))
        #expect(!BundleLocation.isTranslocated("/Applications/AiTerm.app/Contents/Resources"))
        #expect(!BundleLocation.isTranslocated("/Users/me/Sites/AiTerm/build/AiTerm.app/Contents/Resources"))
    }

    @Test func testClaudeAndCodexInstallersAreIsolatedAndIdempotent() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-installers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let codexURL = home.appendingPathComponent(".codex/config.toml")
        let claudeURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: codexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"foreign\"\n".write(to: codexURL, atomically: true, encoding: .utf8)

        try ClaudeDriver(home: home, daemonPort: 47821, shimPath: "/Applications/AiTerm.app/shim.sh").install()
        let codexBefore = try Data(contentsOf: codexURL)
        let claudeAfterFirstInstall = try Data(contentsOf: claudeURL)
        try ClaudeDriver(home: home, daemonPort: 47821, shimPath: "/Applications/AiTerm.app/shim.sh").install()
        #expect(try Data(contentsOf: codexURL) == codexBefore)
        #expect(try Data(contentsOf: claudeURL) == claudeAfterFirstInstall)

        try CodexDriver(home: home, daemonPort: 47821).install()
        let claudeBefore = try Data(contentsOf: claudeURL)
        let codexAfterFirstInstall = try Data(contentsOf: codexURL)
        try CodexDriver(home: home, daemonPort: 47821).install()
        #expect(try Data(contentsOf: claudeURL) == claudeBefore)
        #expect(try Data(contentsOf: codexURL) == codexAfterFirstInstall)
    }

    @Test func testPerHarnessInstallationProbesReadOnlyTheirOwnConfiguration() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-probes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let shim = "/Applications/AiTerm.app/shim.sh"

        #expect(ClaudeDriver(home: home, daemonPort: 47821, shimPath: shim).state != .current)
        #expect(CodexDriver(home: home, daemonPort: 47821).state != .current)
        try ClaudeDriver(home: home, daemonPort: 47821, shimPath: shim).install()
        #expect(ClaudeDriver(home: home, daemonPort: 47821, shimPath: shim).state == .current)
        #expect(CodexDriver(home: home, daemonPort: 47821).state != .current)
        try CodexDriver(home: home, daemonPort: 47821).install()
        #expect(ClaudeDriver(home: home, daemonPort: 47821, shimPath: shim).state == .current)
        #expect(CodexDriver(home: home, daemonPort: 47821).state == .current)
    }


    // MARK: - Merge-only means the user's file stays theirs

    func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        return home
    }

    /// Dotfile managers keep `settings.json` and `config.toml` as symlinks into a repository. An
    /// atomic write replaced the link with a regular file, silently forking the user's config.
    @Test func symlinkedConfigFilesStaySymlinksAndTheirTargetsAreMerged() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let dotfiles = home.appendingPathComponent("dotfiles")
        try fm.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let claudeTarget = dotfiles.appendingPathComponent("claude-settings.json")
        let codexTarget = dotfiles.appendingPathComponent("codex-config.toml")
        try Data(emdashSettings.utf8).write(to: claudeTarget)
        try "model = \"foreign\"\n".write(to: codexTarget, atomically: true, encoding: .utf8)
        let claudeLink = home.appendingPathComponent(".claude/settings.json"), codexLink = home.appendingPathComponent(".codex/config.toml")
        try fm.createSymbolicLink(at: claudeLink, withDestinationURL: claudeTarget)
        try fm.createSymbolicLink(at: codexLink, withDestinationURL: codexTarget)

        try ClaudeDriver(home: home, daemonPort: 47821, shimPath: "/Applications/AiTerm.app/shim.sh").install()
        try CodexDriver(home: home, daemonPort: 47821).install()

        #expect(try fm.destinationOfSymbolicLink(atPath: claudeLink.path) == claudeTarget.path)
        #expect(try fm.destinationOfSymbolicLink(atPath: codexLink.path) == codexTarget.path)
        #expect(ClaudeDriver(home: home, daemonPort: 47821, shimPath: "/Applications/AiTerm.app/shim.sh").state == .current)
        #expect(try String(contentsOf: codexTarget, encoding: .utf8).contains(CodexHookConfig.begin))
        // The backup is a copy of what the link pointed at, not a second link to the merged file.
        for (link, original) in [(claudeLink, Data(emdashSettings.utf8)), (codexLink, Data("model = \"foreign\"\n".utf8))] {
            let backup = link.appendingPathExtension("aiterm-backup")
            #expect(try fm.attributesOfItem(atPath: backup.path)[.type] as? FileAttributeType == .typeRegular)
            #expect(try Data(contentsOf: backup) == original)
        }
    }

    /// A link whose target is gone is not "no settings yet": writing would replace the link with a
    /// regular file and cut the user's config off from the repository it lives in.
    @Test func aDanglingSymlinkIsLeftAloneAndReported() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let missing = home.appendingPathComponent("dotfiles/gone")
        let claudeLink = home.appendingPathComponent(".claude/settings.json"), codexLink = home.appendingPathComponent(".codex/config.toml")
        try fm.createSymbolicLink(atPath: claudeLink.path, withDestinationPath: missing.appendingPathExtension("json").path)
        try fm.createSymbolicLink(atPath: codexLink.path, withDestinationPath: missing.appendingPathExtension("toml").path)

        let claudeError = #expect(throws: HarnessDriverError.self) {
            try ClaudeDriver(home: home, daemonPort: 47821, shimPath: "/Applications/AiTerm.app/shim.sh").install()
        }
        let codexError = #expect(throws: HarnessDriverError.self) { try CodexDriver(home: home, daemonPort: 47821).install() }
        #expect(claudeError?.localizedDescription
                == "Refusing to change ~/.claude/settings.json: it links to \(missing.appendingPathExtension("json").path), which does not exist.")
        #expect(codexError?.localizedDescription
                == "Refusing to change ~/.codex/config.toml: it links to \(missing.appendingPathExtension("toml").path), which does not exist.")
        for (link, ext) in [(claudeLink, "json"), (codexLink, "toml")] {
            #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == missing.appendingPathExtension(ext).path)
            #expect(!fm.fileExists(atPath: missing.appendingPathExtension(ext).path), "the missing target is not created")
            #expect(!fm.fileExists(atPath: link.appendingPathExtension("aiterm-backup").path))
        }
    }

    /// `JSONSerialization` escapes `/` by default, so every path in the user's file came back as `\/`.
    @Test func mergedSettingsKeepSlashesUnescaped() throws {
        let (merged, _) = try ClaudeSettings.merge(Data(emdashSettings.utf8), hookURL: "http://127.0.0.1:47821/hook/claude", shimPath: "/Applications/AiTerm.app/shim.sh")
        let text = try #require(String(data: merged, encoding: .utf8))
        #expect(text.contains(#""/Users/me/.emdash/hook.sh""#))
        #expect(!text.contains(#"\/"#))
    }

    /// Another tool's formatting — compact, escaped slashes, a float that `JSONSerialization` would
    /// print as `1.1000000000000001` — is not a reason to rewrite a file that already says the same.
    @Test func anAlreadyCorrectFileIsNotRewrittenOrBackedUp() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let shim = "/Applications/AiTerm.app/shim.sh"
        let settings = home.appendingPathComponent(".claude/settings.json")
        let (merged, _) = try ClaudeSettings.merge(nil, hookURL: "http://127.0.0.1:47821/hook/claude", shimPath: shim)
        var obj = try JSONSerialization.jsonObject(with: merged) as! [String: Any]
        obj["model"] = "opus"
        let compact = try JSONSerialization.data(withJSONObject: obj)
        let foreign = String(data: compact, encoding: .utf8)!.replacingOccurrences(of: #""model":"opus""#, with: #""model":"opus","ratio":1.1"#)
        try Data(foreign.utf8).write(to: settings)

        try ClaudeDriver(home: home, daemonPort: 47821, shimPath: shim).install()
        #expect(try String(contentsOf: settings, encoding: .utf8) == foreign)
        #expect(!FileManager.default.fileExists(atPath: settings.appendingPathExtension("aiterm-backup").path))
    }

    /// An unreadable file is not a missing one: merging "nothing" and writing the result would
    /// replace the user's settings with AiTerm's entries alone.
    @Test func anUnreadableSettingsFileIsLeftAloneAndReported() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        try Data(emdashSettings.utf8).write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path) }

        #expect(throws: HarnessDriverError.self) {
            try ClaudeDriver(home: home, daemonPort: 47821, shimPath: "/Applications/AiTerm.app/shim.sh").install()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path)
        #expect(try Data(contentsOf: settings) == Data(emdashSettings.utf8))
    }

    @Test func aCodexConfigThatIsNotUTF8IsLeftAloneAndReported() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        let latin1 = Data("name = \"caf".utf8) + Data([0xE9]) + Data("\"\n".utf8)
        try latin1.write(to: config)

        #expect(throws: HarnessDriverError.self) { try CodexDriver(home: home, daemonPort: 47821).install() }
        #expect(try Data(contentsOf: config) == latin1)
    }

    /// Whatever the user (or `codex` itself) appends after AiTerm's block is theirs. The block
    /// still reads as current, and a repair rewrites it where it stands instead of moving it last.
    @Test func codexContentAfterTheBlockNeitherOutdatesNorMovesIt() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        let installed = CodexHookConfig.merge("model = \"gpt-5.6\"\n", hookURL: "http://127.0.0.1:47821")
        let text = installed + "\n[profiles.fast]\nmodel = \"gpt-5.6-mini\"\n"
        try text.write(to: config, atomically: true, encoding: .utf8)

        #expect(CodexDriver(home: home, daemonPort: 47821).state == .current)
        try CodexDriver(home: home, daemonPort: 47821).install()
        #expect(try String(contentsOf: config, encoding: .utf8) == text)

        #expect(CodexDriver(home: home, daemonPort: 9999).state != .current)
        let repaired = CodexHookConfig.merge(text, hookURL: "http://127.0.0.1:9999")
        #expect(repaired == text.replacingOccurrences(of: "127.0.0.1:47821", with: "127.0.0.1:9999"))
    }

    /// Installs from before the shim read plain text kept only the JSON record. The shim no longer
    /// parses it, so the next install writes the command out once, and the user's status line
    /// keeps showing.
    @Test func anOldJSONRecordOfTheOriginalCommandIsMigratedOnce() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let shim = "/Applications/AiTerm.app/shim.sh"
        let support = home.appendingPathComponent("Library/Application Support/AiTerm")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data(#"{"type":"command","command":"~/bin/my status.sh --short"}"#.utf8).write(to: support.appendingPathComponent("statusline-original.json"))
        try Data(#"{"statusLine":{"type":"command","command":"\#(shim)","padding":0}}"#.utf8).write(to: home.appendingPathComponent(".claude/settings.json"))

        try ClaudeDriver(home: home, daemonPort: 47821, shimPath: shim).install()
        let command = support.appendingPathComponent("statusline-original.cmd")
        #expect(try String(contentsOf: command, encoding: .utf8) == "~/bin/my status.sh --short")

        // Once: a command file already there is the record, whatever the old JSON says.
        try Data("edited".utf8).write(to: command)
        try ClaudeDriver(home: home, daemonPort: 47821, shimPath: shim).install()
        #expect(try String(contentsOf: command, encoding: .utf8) == "edited")
    }

    /// An upgrade must not wait for Settings' Install or Repair to keep the user's status line
    /// showing: nothing reports an install with only the JSON record as out of date.
    @Test func anOldJSONRecordIsMigratedAtLaunchWithoutAnInstall() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support/AiTerm")
        let command = support.appendingPathComponent("statusline-original.cmd")
        try StatusLineOriginal.migrate(home: home)
        #expect(!FileManager.default.fileExists(atPath: command.path), "no record, nothing to write")

        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data(#"{"type":"command","command":"~/bin/my status.sh --short"}"#.utf8).write(to: support.appendingPathComponent("statusline-original.json"))
        try StatusLineOriginal.migrate(home: home)
        #expect(try String(contentsOf: command, encoding: .utf8) == "~/bin/my status.sh --short")

        try Data("edited".utf8).write(to: command)
        try StatusLineOriginal.migrate(home: home)
        #expect(try String(contentsOf: command, encoding: .utf8) == "edited", "once")
    }

    /// TOML forbids extending an array or table that is already set inline, by a dotted key or by
    /// a plain `[hooks.<event>]` header, so appending `[[hooks.<event>]]` after one would make
    /// Codex refuse the whole config. The file is reported and left alone instead.
    @Test(arguments: [
        ("hooks.Stop = [{ matcher = \"\" }]\n", "hooks.Stop"),
        ("[hooks]\nStop = [{ matcher = \"\" }]\n", "hooks.Stop"),
        ("[hooks]\nSessionStart.matcher = \"x\"\n", "hooks.SessionStart"),
        ("hooks = { Stop = [] }\n", "hooks"),
        ("[hooks.PermissionRequest]\nmatcher = \"\"\n", "hooks.PermissionRequest"),
        ("\"hooks\" . 'UserPromptSubmit' = []\n", "hooks.UserPromptSubmit"),
    ])
    func aCodexEventSetInAFormTOMLCannotExtendIsRefused(text: String, key: String) throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        try text.write(to: config, atomically: true, encoding: .utf8)
        let driver = CodexDriver(home: home, daemonPort: 47821)

        #expect(driver.probe() == DriverProbe(state: .unreadable,
                                              explanation: "~/.codex/config.toml sets \(key) in a form AiTerm cannot merge."))
        #expect(throws: HarnessDriverError.refused(path: "~/.codex/config.toml", reason: "sets \(key) in a form AiTerm cannot merge")) {
            try driver.install()
        }
        #expect(try String(contentsOf: config, encoding: .utf8) == text)
    }

    /// Another event, or AiTerm's own array-of-tables entries, are no conflict.
    @Test(arguments: ["[hooks]\nPreToolUse = []\n", "hooks.PostToolUse = []\n", "[[hooks.Stop]]\nmatcher = \"x\"\n[hooks.Stop.extra]\na = 1\n"])
    func otherHookAssignmentsStillMerge(text: String) throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        try text.write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        let driver = CodexDriver(home: home, daemonPort: 47821)
        #expect(driver.state == .missing)
        try driver.install()
        #expect(driver.state == .current)
    }

    // MARK: - The Claude card tells the truth about the status line

    /// The footer asks whether Claude Code can run the status line; the card asks whether it is
    /// this bundle's. A path that was this bundle's once and runs nothing now agrees with neither,
    /// so the card has to offer the Repair that repoints it.
    @Test func aStatusLineNamingAShimThatNoLongerRunsIsOutdatedNotCurrent() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let gone = "/old/AiTerm.app/Contents/Resources/hooks/claude-statusline-shim.sh"
        let now = "/new/AiTerm.app/Contents/Resources/hooks/claude-statusline-shim.sh"
        try ClaudeDriver(home: home, daemonPort: 47821, shimPath: gone).install()
        #expect(ClaudeDriver(home: home, daemonPort: 47821, shimPath: gone).state == .current)

        let moved = ClaudeDriver(home: home, daemonPort: 47821, shimPath: now)
        #expect(moved.state == .outdated)
        try moved.install()
        #expect(moved.state == .current, "Repair repoints it")
    }

    /// A shim that still runs from another place is a working feed: the card agrees with the footer.
    @Test func aStatusLineNamingAnotherShimThatStillRunsStaysCurrent() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let elsewhere = home.appendingPathComponent("claude-statusline-shim.sh")
        try "#!/bin/zsh\nexit 0\n".write(to: elsewhere, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: elsewhere.path)
        try ClaudeDriver(home: home, daemonPort: 47821, shimPath: elsewhere.path).install()
        #expect(ClaudeDriver(home: home, daemonPort: 47821, shimPath: "/new/AiTerm.app/hooks/claude-statusline-shim.sh").state == .current)
    }

    // MARK: - CH-11: the Claude merge refuses what it cannot merge

    private func refusal(_ settings: String, key: String) throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".claude/settings.json")
        try settings.write(to: file, atomically: true, encoding: .utf8)
        let driver = ClaudeDriver(home: home, daemonPort: 47821, shimPath: "/Applications/AiTerm.app/shim.sh")
        let reason = "sets \(key) in a form AiTerm cannot merge"

        #expect(driver.probe() == DriverProbe(state: .unreadable, explanation: "~/.claude/settings.json \(reason)."))
        #expect(throws: HarnessDriverError.refused(path: "~/.claude/settings.json", reason: reason)) { try driver.install() }
        #expect(try String(contentsOf: file, encoding: .utf8) == settings, "refused means untouched")
        #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension("aiterm-backup").path))
    }

    @Test func aHooksValueThatIsNotAnObjectIsRefusedNotReplaced() throws {
        try refusal(#"{"hooks": ["something"], "model": "opus"}"#, key: "hooks")
    }

    @Test func anEventThatIsNotAnArrayOfObjectsIsRefusedNotReplaced() throws {
        try refusal(#"{"hooks": {"Stop": "echo done"}}"#, key: "hooks.Stop")
    }

    /// One malformed element used to void the whole array, Emdash's valid entries with it.
    @Test func aMalformedElementBesideEmdashsEntryIsRefusedNotDropped() throws {
        try refusal(#"{"hooks": {"Notification": [{"matcher": "", "hooks": [{"type": "command", "command": "/e/hook.sh", "_emdash": true}]}, 7]}}"#,
                    key: "hooks.Notification")
    }

    @Test func aStatusLineThatIsNotAnObjectIsRefusedNotReplaced() throws {
        try refusal(#"{"statusLine": "~/bin/line.sh"}"#, key: "statusLine")
    }

    /// JSON's `null` says the key is unset, which is how a tool that clears a value writes it: the
    /// merge fills it in as it would a missing key, rather than refusing the file.
    @Test(arguments: [#"{"hooks": null, "model": "opus"}"#, #"{"hooks": {"Stop": null}}"#, #"{"statusLine": null}"#])
    func aNullIsAnAbsentKeyNotARefusal(_ settings: String) throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".claude/settings.json")
        try settings.write(to: file, atomically: true, encoding: .utf8)
        let driver = ClaudeDriver(home: home, daemonPort: 47821, shimPath: "/Applications/AiTerm.app/shim.sh")

        #expect(driver.probe() == DriverProbe(.missing))
        try driver.install()
        #expect(driver.probe() == DriverProbe(.current))
        let support = home.appendingPathComponent("Library/Application Support/AiTerm")
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("statusline-original.cmd").path),
                "a null status line is no original to keep")
    }

    @Test func anEventAiTermDoesNotManageIsNeverARefusal() throws {
        let (data, _) = try ClaudeSettings.merge(
            Data(#"{"hooks": {"PostToolUse": "whatever"}}"#.utf8), hookURL: "u", shimPath: "s")
        let hooks = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["hooks"] as? [String: Any])
        #expect(hooks["PostToolUse"] as? String == "whatever")
    }

    /// Only `type` and `command` are ours to set; whatever else the user or a newer Claude Code
    /// put on the status line stays, whether it was theirs or our shim at an old path.
    @Test func repointingTheStatusLineKeepsItsOtherKeys() throws {
        let theirs = #"{"statusLine": {"type": "command", "command": "/u/line.py", "padding": 3, "refreshInterval": 5}}"#
        let (data, original) = try ClaudeSettings.merge(Data(theirs.utf8), hookURL: "u", shimPath: "/n/shim.sh")
        let line = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["statusLine"] as? [String: Any])
        #expect(line["command"] as? String == "/n/shim.sh" && line["type"] as? String == "command")
        #expect(line["padding"] as? Int == 3 && line["refreshInterval"] as? Int == 5)
        #expect(original?["command"] as? String == "/u/line.py")

        let moved = #"{"statusLine": {"type": "command", "command": "/old/claude-statusline-shim.sh", "refreshInterval": 5}}"#
        let (again, none) = try ClaudeSettings.merge(Data(moved.utf8), hookURL: "u", shimPath: "/n/claude-statusline-shim.sh")
        let repointed = try #require((try JSONSerialization.jsonObject(with: again) as? [String: Any])?["statusLine"] as? [String: Any])
        #expect(repointed["refreshInterval"] as? Int == 5 && repointed["padding"] as? Int == 0)
        #expect(none == nil)
    }

    // MARK: - CH-12: TOML gaps

    @Test(arguments: [
        ("[hooks.Stop.hooks]\ntype = \"command\"\n", "hooks.Stop"),
        ("[hooks.Stop.x]\na = 1\n", "hooks.Stop"),
        ("[[hooks.SessionStart.hooks]]\ntype = \"command\"\n", "hooks.SessionStart"),
    ])
    func aSubTableThatImpliesTheEventIsATableIsRefused(text: String, key: String) throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        try text.write(to: config, atomically: true, encoding: .utf8)
        let driver = CodexDriver(home: home, daemonPort: 47821)
        #expect(CodexHookConfig.conflict(in: text) == key)
        #expect(throws: HarnessDriverError.refused(path: "~/.codex/config.toml", reason: "sets \(key) in a form AiTerm cannot merge")) {
            try driver.install()
        }
        #expect(try String(contentsOf: config, encoding: .utf8) == text)
    }

    @Test func aSubTableAfterItsArrayParentIsNoConflict() {
        #expect(CodexHookConfig.conflict(in: "[[hooks.Stop]]\nmatcher = \"\"\n[hooks.Stop.x]\na = 1\n[[hooks.Stop.hooks]]\n") == nil)
        #expect(CodexHookConfig.conflict(in: "[hooks.PreToolUse.x]\na = 1\n") == nil, "an event AiTerm does not manage")
    }

    @Test(arguments: ["[a]\nx = 1]\n", "[a]\nx = [1, 2\n", "x = { a = 1 \n[b]\n", "x = 1 }\n"])
    func unbalancedTOMLIsRefusedByBothTOMLDrivers(text: String) throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent(".codex/config.toml")
        try text.write(to: codex, atomically: true, encoding: .utf8)
        #expect(CodexDriver(home: home, daemonPort: 47821).probe()
                == DriverProbe(state: .unreadable, explanation: "~/.codex/config.toml cannot be parsed."))
        #expect(throws: HarnessDriverError.refused(path: "~/.codex/config.toml", reason: "cannot be parsed")) {
            try CodexDriver(home: home, daemonPort: 47821).install()
        }
        #expect(try String(contentsOf: codex, encoding: .utf8) == text)

        let grokHome = try temporaryHome(); defer { try? FileManager.default.removeItem(at: grokHome) }
        let grok = grokHome.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: grok.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: grok, atomically: true, encoding: .utf8)
        let driver = GrokDriver(home: grokHome, daemonPort: 47821, shimPath: "/A/grok-statusline-shim.sh")
        #expect(driver.probe() == DriverProbe(state: .unreadable, explanation: "~/.grok/config.toml cannot be parsed."))
        #expect(throws: HarnessDriverError.refused(path: "~/.grok/config.toml", reason: "cannot be parsed")) { try driver.install() }
        #expect(try String(contentsOf: grok, encoding: .utf8) == text)
        #expect(!FileManager.default.fileExists(atPath: GrokHooksFile.url(home: grokHome).path), "nothing written first")
    }

    @Test func bracketsInStringsAndCommentsAreBalanced() {
        #expect(TOMLStatements.isBalanced("a = \"]\"\nb = '['\n# ] [ {\nc = [ [1], {x = 2} ]\n[t]\n[[u]]\nd = \"\"\"]\n\"\"\"\n"))
        #expect(!TOMLStatements.isBalanced("a = 1]\n"))
        #expect(!TOMLStatements.isBalanced("a = [1\n"))
        #expect(!TOMLStatements.isBalanced("a = \"open\n"))
    }
}
