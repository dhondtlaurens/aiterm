import Foundation

/// What a worker's ended turn says to the Operator (spec §E, §J): whether its last message asks the Operator something,
/// and the question it asks; whether work was done in its worktree after its task was accepted. The app reads the last
/// message (`WorkerTranscript.lastMessage`) and the worktree once each turn ends; `RunStatus` lists what they show.
public enum WorkerTurn {
    /// The most of a worker's question `run_status` carries.
    public static let questionLimit = 300

    /// What a working task's line says of its worker's ended turn in place of `ready for the Operator`.
    public enum Ending: Equatable, Sendable {
        /// Its last message ends with a question: `asking the Operator`.
        case asks
        /// Its branch holds no commit past where its work starts: `Operator watching · no commit`.
        case noCommit
    }

    /// The ending a turn that left `lastMessage` and `commitsAhead` shows; nil for a turn that is simply done. A reopened
    /// task still on the commit it was accepted on (`atReopenedCommit`) has that commit to accept again: no `no commit`.
    public static func ending(lastMessage: String?, commitsAhead: Int?, atReopenedCommit: Bool = false) -> Ending? {
        if endsWithQuestion(lastMessage) { return .asks }
        return commitsAhead == 0 && !atReopenedCommit ? .noCommit : nil
    }

    /// What is stripped from the end of a message's last line before its question mark is looked for: markdown emphasis
    /// (`**Ready?**`) and spaces.
    private static let trailing = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_`~"))

    /// Whether the worker left a pending question: an explicit Question marker, a scope decision
    /// it stopped for, or its final question with any answer choices. Trailing status does not answer a marked question.
    static func endsWithQuestion(_ lastMessage: String?) -> Bool { questionLines(lastMessage) != nil }

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
    static func question(_ lastMessage: String) -> String {
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

    /// Whether an accepted task's worktree moved on from what was accepted: it has changes not committed (`git status
    /// --porcelain` says something), or its HEAD is another commit than `accepted`. A HEAD git couldn't read says nothing.
    public static func changedAfterAcceptance(porcelain: String, head: String?, accepted: String?) -> Bool {
        guard let accepted, !accepted.isEmpty else { return false }
        if !porcelain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let head, !head.isEmpty else { return false }
        return !OperatedTransitions.sameCommit(head, accepted)
    }
}

public extension Repository {
    /// One baseline for both a working task's diff and its commit count. Local and origin refs
    /// can each lag; the launch fork also survives a reset or removal of those refs. A stacked
    /// task keeps its parent's accepted boundary, reduced to the actual shared ancestor after rebase.
    func taskDiffBase(stackedOn parent: String?, baseBranch: String, savedBase: String? = nil) throws -> String? {
        if let parent, !parent.isEmpty { return try mergeBase(parent, "HEAD") ?? parent }
        let branch = baseBranch.isEmpty ? defaultBranch() : baseBranch
        let refs = [savedBase, branch, "refs/remotes/origin/" + branch].compactMap { $0 }
        let candidates = try refs.compactMap { try mergeBase($0, "HEAD") }
        guard var base = candidates.first else { return nil }
        for candidate in candidates.dropFirst() where candidate != base {
            if try isAncestor(base, of: candidate) { base = candidate }
        }
        return base
    }

    /// How many commits HEAD has past where a working task's work starts, without fetching: the commit it was accepted on
    /// before it was steered back to work (`reopenedFrom`), else the same saved/local/origin boundary
    /// as its diff (`taskDiffBase`), with its stacked parent's boundary preserved. Nil when git couldn't count.
    func commitsAhead(reopenedFrom: String?, stackedOn parent: String?, baseBranch: String, savedBase: String? = nil) -> Int? {
        let base: String
        if let reopenedFrom, !reopenedFrom.isEmpty { base = reopenedFrom }
        else {
            guard let found = try? taskDiffBase(stackedOn: parent, baseBranch: baseBranch, savedBase: savedBase) else { return nil }
            base = found
        }
        return count(base, "HEAD")
    }
}
