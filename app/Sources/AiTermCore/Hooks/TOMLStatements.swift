import Foundation

/// A lossless view of TOML text as top-level statements, split only at newlines outside strings,
/// arrays and inline tables. Comments stay in `text`, out of `code`. It reads structure only (headers,
/// key paths, statement boundaries), never values, so one table of a user's file can be edited while
/// every other byte, comment and table is kept exactly.
enum TOMLStatements {
    struct Statement {
        var text: String
        var code: String
        var header: (path: [String], array: Bool)? {
            let array = code.hasPrefix("[[")
            let bracket = array ? 2 : 1
            guard code.hasPrefix("["), code.hasSuffix(array ? "]]" : "]") else { return nil }
            return (Self.path(String(code.dropFirst(bracket).dropLast(bracket))), array)
        }
        /// The key an assignment names, split at its dots: `a."b.c" = 1` names `["a", "b.c"]`.
        /// `nil` for headers, comments and blank lines.
        var keyPath: [String]? {
            guard header == nil, let equals = Self.equals(in: code) else { return nil }
            return Self.path(String(code[..<equals]))
        }
        /// The `=` that ends a key: the first outside a quoted key such as `"a=b"`.
        private static func equals(in code: String) -> String.Index? {
            var quote: Character?, escaped = false
            for index in code.indices {
                let c = code[index]
                if let q = quote {
                    if escaped { escaped = false }
                    else if q == "\"" && c == "\\" { escaped = true }
                    else if c == q { quote = nil }
                } else if c == "\"" || c == "'" { quote = c }
                else if c == "=" { return index }
            }
            return nil
        }

        /// A dotted key split at its dots outside quotes. A part wrapped in matching quotes loses
        /// them, with no escape decoding; other parts are trimmed of spaces.
        static func path(_ raw: String) -> [String] {
            var parts: [String] = [], part = "", quote: Character?, escaped = false
            for c in raw {
                if let q = quote {
                    part.append(c)
                    if escaped { escaped = false }
                    else if q == "\"" && c == "\\" { escaped = true }
                    else if c == q { quote = nil }
                } else if c == "\"" || c == "'" { quote = c; part.append(c) }
                else if c == "." { parts.append(part); part = "" }
                else { part.append(c) }
            }
            parts.append(part)
            return parts.map { raw in
                let part = raw.trimmingCharacters(in: .whitespaces)
                guard part.count >= 2, let quote = part.first, quote == "\"" || quote == "'", part.last == quote else { return part }
                return String(part.dropFirst().dropLast())
            }
        }
    }

    struct Table {
        var statements: [Statement]
        var path: [String] { statements.first?.header?.path ?? [] }
        var array: Bool { statements.first?.header?.array ?? false }
        var text: String { statements.map(\.text).joined() }
    }

    static func tables(_ text: String) -> [Table] { parsed(text).tables }

    /// `text`'s tables, and whether every bracket and brace outside a string or comment closes what
    /// it opened, and no string is left open. Otherwise the statements have lost their place: a stray
    /// `]` takes the depth below zero and the rest of the file reads as one statement, hiding every
    /// later header. Codex rejects such a file, so an editor has no business appending to it.
    static func parsed(_ text: String) -> (tables: [Table], balanced: Bool) {
        let scanned = scan(text)
        var result = [Table(statements: [])]
        for statement in scanned.statements {
            if statement.header != nil { result.append(Table(statements: [])) }
            result[result.count - 1].statements.append(statement)
        }
        return (result, scanned.balanced)
    }

    /// Split only at top-level newlines. A table-looking line inside a multiline string or
    /// array is data, never a table to edit. Keep comments in `text`, but out of `code`.
    static func statements(_ text: String) -> [Statement] { scan(text).statements }

    private static func scan(_ text: String) -> (statements: [Statement], balanced: Bool) {
        let chars = Array(text)
        var result: [Statement] = [], raw = "", code = ""
        var quote: Character?, multiline = false, escaped = false, comment = false, depth = 0, i = 0
        var balanced = true
        func emit() {
            result.append(Statement(text: raw, code: code.trimmingCharacters(in: .whitespacesAndNewlines)))
            raw = ""; code = ""
        }
        while i < chars.count {
            let c = chars[i]
            raw.append(c)
            if comment {
                if c.isNewline { comment = false; if depth == 0 { emit() } else { code.append(c) } }
                i += 1; continue
            }
            if let q = quote {
                code.append(c)
                if escaped { escaped = false }
                else if q == "\"" && c == "\\" { escaped = true }
                else if c == q {
                    if !multiline { quote = nil }
                    else if i + 2 < chars.count, chars[i + 1] == q, chars[i + 2] == q {
                        // Four/five closing quotes include one/two literal quotes in the value.
                        var extra = 2
                        while extra < 4 && i + extra + 1 < chars.count && chars[i + extra + 1] == q { extra += 1 }
                        raw += String(repeating: String(q), count: extra)
                        code += String(repeating: String(q), count: extra)
                        i += extra; quote = nil; multiline = false
                    }
                }
            } else if c == "#" { comment = true }
            else {
                code.append(c)
                if c == "\"" || c == "'" {
                    quote = c
                    multiline = i + 2 < chars.count && chars[i + 1] == c && chars[i + 2] == c
                    if multiline {
                        raw += String(repeating: String(c), count: 2)
                        code += String(repeating: String(c), count: 2)
                        i += 2
                    }
                } else if c == "[" || c == "{" { depth += 1 }
                else if c == "]" || c == "}" {
                    depth -= 1
                    if depth < 0 { balanced = false }
                }
                else if c.isNewline && depth == 0 { emit() }
            }
            i += 1
        }
        if !raw.isEmpty { emit() }
        return (result, balanced && depth == 0 && quote == nil)
    }
}
