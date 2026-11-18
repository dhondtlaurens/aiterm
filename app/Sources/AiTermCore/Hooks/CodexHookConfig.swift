import Foundation

/// What AiTerm merges into Codex's `config.toml` — command hooks for its lifecycle events and an
/// MCP server for `Stop` — between marker comments, and how it recognises its own tables there.
/// `CodexDriver` reads and writes the file. The merge works on a lossless view of TOML statements
/// and reads table paths only, never a string value; every byte it does not own is kept.
enum CodexHookConfig {
    static let events = ["SessionStart", "UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop", "PermissionRequest"]
    static let begin = "# >>> aiterm hooks >>>", end = "# <<< aiterm hooks <<<"

    /// The canonical driver tables, with markers for humans reading the file.
    static func block(hookURL: String) -> String {
        var block = begin + "\n"
        // Codex starts command hooks in the session cwd. A merge workflow can remove that cwd
        // before Stop fires, making curl fail to spawn with ENOENT. Keep the final lifecycle event
        // on a persistent MCP connection instead; the other events remain lightweight async posts.
        block += "[mcp_servers.aiterm_hooks]\n"
        block += "url = \"\(hookURL)/mcp\"\nenabled = true\nrequired = false\nenabled_tools = [\"post_codex_hook\"]\n\n"
        block += "[mcp_servers.aiterm_hooks.http_headers]\nX-AiTerm-Hook = \"1\"\n\n"
        block += "[mcp_servers.aiterm_hooks.env_http_headers]\nX-AiTerm-iTerm-Session = \"ITERM_SESSION_ID\"\n\n"
        for event in events {
            block += "[[hooks.\(event)]]\nmatcher = \"\"\n[[hooks.\(event).hooks]]\n"
            if event == "Stop" {
                block += "type = \"mcp_tool\"\nserver = \"aiterm_hooks\"\ntool = \"post_codex_hook\"\n"
                block += "input = { session_id = \"${session_id}\", cwd = \"${cwd}\", hook_event_name = \"${hook_event_name}\", model = \"${model}\", turn_id = \"${turn_id}\", stop_hook_active = \"${stop_hook_active}\", last_assistant_message = \"${last_assistant_message}\" }\n"
                block += "timeout = 5\n\n"
            } else {
                block += "type = \"command\"\ncommand = 'curl -s -m 2 -X POST -H \"Content-Type: application/json\" -H \"X-AiTerm-Hook: 1\" -H \"X-AiTerm-iTerm-Session: $ITERM_SESSION_ID\" -H \"Expect:\" --data-binary @- \(hookURL)/hook/codex'\ntimeout = 5\nasync = true\n\n"
            }
        }
        return block + end
    }

    /// The file holds something of AiTerm's to repair: a marker, or AiTerm's MCP server table.
    static func hasAiTermEntries(_ tables: [TOMLStatements.Table]) -> Bool {
        tables.contains { $0.path == ["mcp_servers", "aiterm_hooks"] || $0.statements.contains(where: \.marker) }
    }

    /// The key that makes the merge impossible: an event of ours, or `hooks` itself, already set
    /// by an inline or dotted assignment (`hooks.Stop = […]`, `Stop = […]` under `[hooks]`,
    /// `hooks = {…}`), as a plain `[hooks.Stop]` table, or as a table a deeper header implies
    /// (`[hooks.Stop.x]` with no `[[hooks.Stop]]` before it). TOML forbids extending any of them
    /// with `[[hooks.Stop]]`, so appending AiTerm's block would make Codex refuse the whole file.
    static func conflict(in text: String, tables: [TOMLStatements.Table]? = nil) -> String? {
        let events = Set(Self.events)
        var arrayParents: Set<String> = []
        for table in tables ?? TOMLStatements.tables(text) {
            if table.path.count >= 2, table.path[0] == "hooks", events.contains(table.path[1]) {
                if table.array, table.path.count == 2 { arrayParents.insert(table.path[1]) }
                else if table.path.count == 2 || !arrayParents.contains(table.path[1]) { return "hooks.\(table.path[1])" }
            }
            // Keys inside `[[hooks.<event>]]` and its children are that entry's own fields.
            guard table.path.count < 2 else { continue }
            for key in table.statements.compactMap(\.keyPath) {
                let path = table.path + key
                if path == ["hooks"] { return "hooks" }
                if path.count >= 2, path[0] == "hooks", events.contains(path[1]) { return "hooks.\(path[1])" }
            }
        }
        return nil
    }

    /// `toml` with AiTerm's block current and every byte AiTerm does not own kept.
    ///
    /// A marked span runs from a begin-marker statement to the next end-marker statement; a begin
    /// marker with no end after it runs to the end of the file, and an end marker with no begin
    /// before it belongs to no span. Markers are comment-only statements, so a marker inside a
    /// string is data. An AiTerm table is one whose path is `mcp_servers.aiterm_hooks` or below it,
    /// anywhere in the file, or one that starts inside a marked span and whose path is
    /// `hooks.<one of events>` or below it. Every other table is the person's or Codex's, wherever
    /// it stands: Codex adds new tables (approval records, a server from `codex mcp add`) before the
    /// file's trailing comment, which is the end marker.
    ///
    /// In place: when the file has exactly one begin and one end marker, begin first, and every
    /// statement between them belongs to an AiTerm table or is blank, the text from the start of
    /// the begin marker's line to the end of the end marker's text is replaced by
    /// `block(hookURL:)`. Nothing outside that range changes.
    ///
    /// Rebuild, otherwise: every marker statement is dropped; every AiTerm table is dropped except
    /// its standalone comments (a comment after an AiTerm table may document the next table); every
    /// other table is kept with its exact text, its last line ended in the file's own line ending; then the block is
    /// appended after a blank line.
    static func merge(_ toml: String?, hookURL: String, tables: [TOMLStatements.Table]? = nil) -> String {
        let parsed = tables ?? TOMLStatements.tables(toml ?? "")
        let block = Self.block(hookURL: hookURL)
        var inSpan = false
        let aiTerm = parsed.map { table in
            let startsInSpan = inSpan && table.statements.first?.header != nil
            for statement in table.statements where statement.marker { inSpan = statement.isBegin }
            let path = table.path
            return path.starts(with: ["mcp_servers", "aiterm_hooks"])
                || (startsInSpan && path.count >= 2 && path[0] == "hooks" && Self.events.contains(path[1]))
        }

        let markers = parsed.flatMap(\.statements).filter(\.marker)
        if markers.count == 2, markers[0].isBegin, !markers[1].isBegin {
            var before = "", after = "", between = false, ended = false, pristine = true
            for (table, isAiTerm) in zip(parsed, aiTerm) {
                for statement in table.statements {
                    if ended { after += statement.text }
                    else if statement.marker && !between { between = true }
                    else if statement.marker, let end = statement.text.range(of: Self.end) {
                        after += statement.text[end.upperBound...]; ended = true
                    } else if between {
                        if !(statement.blank || (isAiTerm && !statement.code.isEmpty)) { pristine = false }
                    } else { before += statement.text }
                }
            }
            if pristine { return before + block + after }
        }

        var base = zip(parsed, aiTerm).map { table, isAiTerm in
            table.statements.filter { !$0.marker && (!isAiTerm || $0.standaloneComment) }.map(\.text).joined()
        }.joined()
        // By scalar: `"\r\n"` is one Character, so `hasSuffix("\n")` misses a CRLF ending. A last line with none
        // gets the file's own.
        if !base.isEmpty && base.unicodeScalars.last != "\n" { base += base.contains("\r\n") ? "\r\n" : "\n" }
        return base + (base.isEmpty ? "" : "\n") + block + "\n"
    }
}

private extension TOMLStatements.Statement {
    var marker: Bool {
        code.isEmpty && [CodexHookConfig.begin, CodexHookConfig.end].contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    /// A marker that opens a span (only meaningful when `marker`).
    var isBegin: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines) == CodexHookConfig.begin }
    var blank: Bool { code.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var standaloneComment: Bool { code.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") }
}
