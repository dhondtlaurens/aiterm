import Foundation

/// An operator's file (spec §4.0): YAML frontmatter for the settings, then `## Persona` and
/// `## Lessons` in Markdown, so a person can read and edit it like any note.
///
/// The YAML is the small subset the file needs, parsed by hand rather than adding a package: one
/// level of `key: value`, a nested map one level deep (`secondOpinion`, `limits`), a list of
/// `- item` lines (`alwaysAsk`), plain or quoted scalars, and `#` comments. Keys this build does
/// not know are **ignored**, not kept: the operator sheet writes the whole file from the persona,
/// so a key added by hand goes on the next save from AiTerm (`OperatorFileTests` pins that).
public enum OperatorFile {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingFrontmatter
        case missingKey(String)
        case invalidValue(key: String, value: String)
        case unreadableLine(Int, String)

        public var description: String {
            switch self {
            case .missingFrontmatter: return "The file doesn't start with a --- frontmatter block."
            case .missingKey(let key): return "The frontmatter has no \(key)."
            case .invalidValue(let key, let value): return "\(key) can't be “\(value)”."
            case .unreadableLine(let line, let text): return "Line \(line) can't be read: \(text)"
            }
        }
    }

    // MARK: - Parse

    public static func parse(_ text: String) throws(ParseError) -> OperatorPersona {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" })
        else { throw .missingFrontmatter }
        let fields = try frontmatter(Array(lines[1..<close]), firstLine: 2)
        let body = sections(Array(lines[(close + 1)...]))

        func scalar(_ key: String) -> String? { if case .scalar(let v)? = fields[key] { return v } else { return nil } }
        func map(_ key: String) -> [String: String] { if case .map(let m)? = fields[key] { return m } else { return [:] } }
        func required(_ key: String) throws(ParseError) -> String {
            guard let value = scalar(key), !value.isEmpty else { throw .missingKey(key) }
            return value
        }
        func value<T: RawRepresentable>(_ raw: String?, _ key: String, default fallback: T) throws(ParseError) -> T where T.RawValue == String {
            guard let raw else { return fallback }
            guard let parsed = T(rawValue: raw) else { throw .invalidValue(key: key, value: raw) }
            return parsed
        }
        func integer(_ raw: String?, _ key: String, default fallback: Int) throws(ParseError) -> Int {
            guard let raw else { return fallback }
            guard let parsed = Int(raw), parsed >= 0 else { throw .invalidValue(key: key, value: raw) }
            return parsed
        }

        // A file without the block gets the standard second opinion; within the block, a missing
        // effort is none — the agent's own default — as `render` leaves it out.
        let standard = SecondOpinion.standard
        let opinion = map("secondOpinion"), limits = map("limits")
        var list: [String] = []
        if case .list(let items)? = fields["alwaysAsk"] { list = items }
        let secondOpinion = fields["secondOpinion"] == nil ? standard : SecondOpinion(
            level: try value(opinion["level"], "secondOpinion.level", default: standard.level),
            agent: try value(opinion["agent"], "secondOpinion.agent", default: standard.agent),
            model: opinion["model"] ?? standard.model,
            effort: opinion["effort"].flatMap { $0.isEmpty ? nil : $0 })
        return OperatorPersona(
            name: try required("name"), handle: try required("handle"), model: try required("model"),
            effort: scalar("effort").flatMap { $0.isEmpty ? nil : $0 },
            secondOpinion: secondOpinion,
            autonomy: try value(scalar("autonomy"), "autonomy", default: .routine),
            alwaysAsk: list,
            limits: OperatorLimits(retries: try integer(limits["retries"], "limits.retries", default: 2),
                                   runtimeMinutes: try integer(limits["runtimeMinutes"], "limits.runtimeMinutes", default: 90)),
            persona: body.persona, lessons: body.lessons)
    }

    private enum Field: Equatable { case scalar(String), map([String: String]), list([String]) }

    /// The frontmatter's lines as top-level fields. A key with nothing after its colon opens a
    /// block: the indented lines under it are a map of `key: value` or a list of `- item`.
    private static func frontmatter(_ lines: [String], firstLine: Int) throws(ParseError) -> [String: Field] {
        var fields: [String: Field] = [:]
        var open: String?
        for (offset, raw) in lines.enumerated() {
            let number = firstLine + offset
            let content = stripComment(raw)
            guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let indented = content.first == " " || content.first == "\t"
            let line = content.trimmingCharacters(in: .whitespaces)
            if indented {
                guard let key = open else { throw .unreadableLine(number, raw) }
                if line.hasPrefix("- ") || line == "-" {
                    let item = unquote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                    switch fields[key] {
                    case .list(let items)?: fields[key] = .list(items + [item])
                    case nil: fields[key] = .list([item])
                    default: throw .unreadableLine(number, raw)
                    }
                } else if let (sub, value) = pair(line) {
                    switch fields[key] {
                    case .map(var m)?: m[sub] = value; fields[key] = .map(m)
                    case nil: fields[key] = .map([sub: value])
                    default: throw .unreadableLine(number, raw)
                    }
                } else {
                    throw .unreadableLine(number, raw)
                }
            } else {
                guard let (key, value) = pair(line) else { throw .unreadableLine(number, raw) }
                if value.isEmpty, !line.hasSuffix("\"\""), !line.hasSuffix("''") { open = key }
                else { open = nil; fields[key] = .scalar(value) }
            }
        }
        return fields
    }

    /// `key: value`, the value unquoted; nil for a line with no `key:`.
    private static func pair(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(" ") else { return nil }
        return (key, unquote(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
    }

    /// The line without a `#` comment: one at the start of the line or after a space, outside quotes.
    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character = " ", escaped = false
        for (index, char) in zip(line.indices, line) {
            if let open = quote {
                if escaped { escaped = false }
                else if char == "\\", open == "\"" { escaped = true }
                else if char == open { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == "#", previous == " " || previous == "\t" {
                return String(line[..<index])
            }
            previous = char
        }
        return line
    }

    /// A scalar as written: `"…"` with `\"`, `\\` and `\n` escapes, `'…'` with `''`, or bare.
    private static func unquote(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            var out = "", escaping = false
            for char in value.dropFirst().dropLast() {
                if escaping {
                    out.append(char == "n" ? "\n" : char == "t" ? "\t" : char)
                    escaping = false
                } else if char == "\\" {
                    escaping = true
                } else {
                    out.append(char)
                }
            }
            return out
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value
    }

    /// The persona is everything before `## Lessons`, its own `## Persona` heading left out; a
    /// lesson is a `- ` or `* ` bullet under `## Lessons`, an indented line under one continuing it.
    private static func sections(_ lines: [String]) -> (persona: String, lessons: [String]) {
        var persona: [String] = [], lessons: [String] = []
        var inLessons = false
        for line in lines {
            let heading = line.trimmingCharacters(in: .whitespaces).lowercased()
            if heading == "## lessons" { inLessons = true; continue }
            if !inLessons {
                if heading == "## persona", persona.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { persona = []; continue }
                persona.append(line)
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                lessons.append(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if !trimmed.isEmpty, line.first == " " || line.first == "\t", let last = lessons.popLast() {
                lessons.append(last + " " + trimmed)
            }
        }
        return (persona.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), lessons.filter { !$0.isEmpty })
    }

    // MARK: - Render

    /// The file for `persona`. Comments name each stepped setting's stops, as the spec's example
    /// does, so a person editing it by hand sees what else it can be.
    public static func render(_ p: OperatorPersona) -> String {
        var lines = ["---",
                     "name: \(yaml(p.name))",
                     "handle: \(yaml(p.handle))",
                     "model: \(yaml(p.model))"]
        if let effort = p.effort { lines.append("effort: \(yaml(effort))") }
        lines += ["secondOpinion:",
                  "  level: \(p.secondOpinion.level.rawValue)  # noSelfDoubt | healthyDoubt | impostor",
                  "  agent: \(p.secondOpinion.agent.rawValue)",
                  "  model: \(yaml(p.secondOpinion.model))"]
        if let effort = p.secondOpinion.effort { lines.append("  effort: \(yaml(effort))") }
        lines.append("autonomy: \(p.autonomy.rawValue)  # askFirst | routine | trusted | handsOff")
        if p.alwaysAsk.isEmpty { lines.append("alwaysAsk: []") }
        else { lines.append("alwaysAsk:"); lines += p.alwaysAsk.map { "  - \(yaml($0))" } }
        lines += ["limits:",
                  "  retries: \(p.limits.retries)",
                  "  runtimeMinutes: \(p.limits.runtimeMinutes)",
                  "---",
                  "## Persona",
                  ""]
        if !p.persona.isEmpty { lines += [p.persona, ""] }
        lines += ["## Lessons", ""]
        lines += p.lessons.map { "- " + $0.replacingOccurrences(of: "\n", with: " ") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `s` bare when the subset reads it back as it is, double-quoted otherwise.
    static func yaml(_ s: String) -> String {
        let reserved = ["", "~", "null", "true", "false", "yes", "no", "[]"]
        let bare = s.range(of: #"^[A-Za-z0-9_.(/][A-Za-z0-9 _.,/()+-]*$"#, options: .regularExpression) != nil
        if bare, !s.hasSuffix(" "), !reserved.contains(s.lowercased()) { return s }
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
