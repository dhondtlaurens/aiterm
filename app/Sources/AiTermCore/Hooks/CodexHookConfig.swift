import Foundation

/// A lossless view of TOML statements, used only to remove tables we own. In particular, a
/// marker comment is not a boundary: Codex can move hooks out of it and approval records into it.
/// Strings, comments, multiline values and unrelated tables retain their original bytes.
enum CodexHookConfig {
    static func hasOwnedEntries(_ text: String) -> Bool {
        let parsed = TOMLStatements.tables(text)
        return parsed.contains(where: \.owned) || parsed.contains { $0.statements.contains(where: \.marker) }
    }

    /// The key that makes the merge impossible: an event of ours, or `hooks` itself, already set
    /// by an inline or dotted assignment (`hooks.Stop = […]`, `Stop = […]` under `[hooks]`,
    /// `hooks = {…}`), as a plain `[hooks.Stop]` table, or as a table a deeper header implies
    /// (`[hooks.Stop.x]` with no `[[hooks.Stop]]` before it). TOML forbids extending any of them
    /// with `[[hooks.Stop]]`, so appending AiTerm's block would make Codex refuse the whole file.
    static func conflict(in text: String) -> String? {
        let events = Set(HookInstaller.codexEvents)
        var arrayParents: Set<String> = []
        for table in TOMLStatements.tables(text) {
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

    static func merge(_ text: String, hookURL: String) -> String {
        let parsed = TOMLStatements.tables(text)
        let block = HookInstaller.codexBlock(hookURL: hookURL)
        let markers = parsed.flatMap(\.statements).filter(\.marker)
        // Keep a pristine managed block in place, including on a port change. Do not use this
        // shortcut when there are moved/duplicated hooks or foreign content inside the markers.
        if markers.count == 2, let range = blockRange(in: text),
           let oldURL = parsed.first(where: { $0.path == ["mcp_servers", "aiterm_hooks"] })?.values["url"],
           oldURL.hasSuffix("/mcp"),
           text[range] == HookInstaller.codexBlock(hookURL: String(oldURL.dropLast(4))) {
            let outside = String(text[..<range.lowerBound]) + String(text[range.upperBound...])
            if !TOMLStatements.tables(outside).contains(where: \.owned) {
                var result = text; result.replaceSubrange(range, with: block); return result
            }
        }

        var removed = Set(parsed.indices.filter { parsed[$0].owned })
        // TOML child tables refer to the most recent parent of that name, even across unrelated
        // tables. Track that relationship rather than assuming children are adjacent.
        var parents: [String: Int] = [:], hooks: [String: Int] = [:], children: [Int: [Int]] = [:]
        for i in parsed.indices {
            let table = parsed[i]
            guard table.path.count >= 2, table.path[0] == "hooks" else { continue }
            let event = table.path[1]
            if table.array && table.path.count == 2 {
                parents[event] = i; hooks[event] = nil
            } else if table.path.count > 2 {
                if let parent = parents[event] { children[parent, default: []].append(i) }
                if table.path[2] == "hooks" {
                    if table.array && table.path.count == 3 { hooks[event] = i }
                    else if let hook = hooks[event], removed.contains(hook) { removed.insert(i) }
                }
            }
        }
        for (parent, descendants) in children where descendants.allSatisfy({ removed.contains($0) }) {
            removed.insert(parent)
        }
        var base = parsed.indices.map { i in
            if !removed.contains(i) { return parsed[i].textWithoutMarkers }
            // A standalone comment following an owned table may document the next foreign
            // table. Ownership of a hook never grants ownership of those comments.
            return parsed[i].statements.filter {
                !$0.marker && $0.code.isEmpty && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#")
            }.map(\.text).joined()
        }.joined()
        if !base.isEmpty && !base.hasSuffix("\n") { base += "\n" }
        return base + (base.isEmpty ? "" : "\n") + block + "\n"
    }

    private static func blockRange(in text: String) -> Range<String.Index>? {
        var offset = text.startIndex, begin: String.Index?
        for statement in TOMLStatements.statements(text) {
            let end = text.index(offset, offsetBy: statement.text.count)
            if statement.marker {
                if statement.text.trimmingCharacters(in: .whitespacesAndNewlines) == HookInstaller.codexBegin {
                    begin = offset
                } else if let begin, let marker = text.range(of: HookInstaller.codexEnd, range: offset..<end) {
                    return begin..<marker.upperBound
                }
            }
            offset = end
        }
        return nil
    }
}

private extension TOMLStatements.Statement {
    var marker: Bool {
        code.isEmpty && [HookInstaller.codexBegin, HookInstaller.codexEnd].contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private extension TOMLStatements.Table {
    var owned: Bool {
        if path.starts(with: ["mcp_servers", "aiterm_hooks"]) { return true }
        guard array, path.count == 3, path[0] == "hooks", path[2] == "hooks" else { return false }
        let fields = values
        if fields["type"] == "mcp_tool" {
            return fields["server"] == "aiterm_hooks" && fields["tool"] == "post_codex_hook"
        }
        guard fields["type"] == "command", let command = fields["command"] else { return false }
        // Both the explicit ownership header and our endpoint are required. A mention of
        // AiTerm in an unrelated command or comment is not permission to delete that hook.
        return command.hasPrefix("curl ")
            && command.range(of: #"X-A[iI][tT]erm-Hook: 1"#, options: .regularExpression) != nil
            && command.range(of: #"http://(?:127\.0\.0\.1|localhost):[0-9]+/hook/codex(?:['"\s]|$)"#, options: .regularExpression) != nil
    }
    /// The table as Codex's merge writes it back: marker comments are dropped and re-emitted.
    var textWithoutMarkers: String { statements.filter { !$0.marker }.map(\.text).joined() }
}
