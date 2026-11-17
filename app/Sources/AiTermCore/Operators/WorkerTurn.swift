import Foundation

/// Whether a worker's last message asks a question, and the question itself.
public enum WorkerTurn {
    /// The most of a worker's question `run_status` carries.
    public static let questionLimit = 300

    /// What is stripped from the end of a message's last line before its question mark is looked for: markdown emphasis
    /// (`**Ready?**`) and spaces.
    private static let trailing = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_`~"))

    /// Whether the worker left a pending question: an explicit Question marker, a scope decision
    /// it stopped for, or its final question with any answer choices. Trailing status does not answer a marked question.
    public static func endsWithQuestion(_ lastMessage: String?) -> Bool { questionLines(lastMessage) != nil }

    /// Scope stops and explicit Question markers remain pending through trailing status output.
    /// Unmarked historical questions followed by completed work are not requests for an answer.
    private static func questionLines(_ message: String?) -> [String]? {
        guard let message else { return nil }
        let lines = message.components(separatedBy: .newlines)
        var paragraphs: [[String]] = [], current: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { paragraphs.append(current); current = [] }
            } else { current.append(line) }
        }
        if !current.isEmpty { paragraphs.append(current) }
        let lower = message.lowercased()
        let scopeStop = (lower.contains("scope rule") && lower.contains("stop"))
            || lower.contains("outside the authorized scope") || lower.contains("out-of-scope")
            || lower.contains("stopped at a spec question")
        for index in paragraphs.indices.reversed() {
            let paragraph = paragraphs[index].joined(separator: "\n").trimmingCharacters(in: .whitespaces)
            let bare = paragraph.trimmingCharacters(in: CharacterSet(charactersIn: "#*_` "))
            let explicit = bare.range(of: #"^question(?:\*\*)?\s*:"#, options: [.regularExpression, .caseInsensitive]) != nil
            let permission = scopeStop && bare.hasPrefix("May I ") && bare.contains("?")
            let scopeChoice = scopeStop && bare.hasPrefix("Should ") && (bare.contains("?") || bare.hasSuffix(":"))
            guard explicit || permission || scopeChoice else { continue }
            var chosen = paragraphs[index]
            for options in paragraphs.dropFirst(index + 1) {
                guard let first = options.first?.trimmingCharacters(in: .whitespaces),
                      first.hasPrefix("- ") || first.hasPrefix("* ") || first.hasPrefix("• ")
                        || first.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil else { break }
                chosen += [""] + options
            }
            return chosen
        }
        var tail: [String] = []
        for line in lines.reversed() {
            let raw = line.trimmingCharacters(in: .whitespaces)
            let text = raw.trimmingCharacters(in: trailing)
            if text.isEmpty { continue }
            tail.insert(line, at: 0)
            if text.hasSuffix("?") { return tail }
            let option = raw.hasPrefix("- ") || raw.hasPrefix("* ") || raw.hasPrefix("• ")
                || raw.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
            if !option { return nil }
        }
        return nil
    }

    /// The question and any answer choices, cut to the tool's display limit.
    public static func question(_ lastMessage: String) -> String {
        let lines = lastMessage.components(separatedBy: .newlines)
        var paragraph: [String] = []
        for line in lines.reversed() {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, !paragraph.isEmpty { break }
            if !blank { paragraph.insert(line, at: 0) }
        }
        let question = questionLines(lastMessage)
        let chosen = question?.first.map { paragraph.contains($0) ? paragraph : question! } ?? paragraph
        let text = chosen.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > questionLimit ? String(text.prefix(questionLimit - 1)) + "…" : text
    }
}
