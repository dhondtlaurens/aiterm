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

    /// Whether the message's last line that says something, its markdown emphasis and spaces stripped, ends with `?`. A
    /// question earlier in the message is one the worker went on past.
    public static func endsWithQuestion(_ lastMessage: String?) -> Bool {
        guard let line = lastMessage?.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: trailing).isEmpty })
        else { return false }
        return line.trimmingCharacters(in: trailing).hasSuffix("?")
    }

    /// The question as `run_status` carries it: the message's last paragraph, cut to `questionLimit` characters.
    public static func question(_ lastMessage: String) -> String {
        let lines = lastMessage.components(separatedBy: .newlines)
        var paragraph: [String] = []
        for line in lines.reversed() {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, !paragraph.isEmpty { break }
            if !blank { paragraph.insert(line, at: 0) }
        }
        let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// How many commits HEAD has past where a working task's work starts, without fetching: the commit it was accepted on
    /// before it was steered back to work (`reopenedFrom`), else its stacked parent's accepted commit, else origin's copy
    /// of its base branch as this clone last fetched it, else the local base branch. `baseBranch` empty is the default
    /// branch. Nil when git couldn't count.
    func commitsAhead(reopenedFrom: String?, stackedOn parent: String?, baseBranch: String) -> Int? {
        let base: String
        if let reopenedFrom, !reopenedFrom.isEmpty { base = reopenedFrom }
        else if let parent, !parent.isEmpty { base = parent }
        else {
            let branch = baseBranch.isEmpty ? defaultBranch() : baseBranch
            base = sha("refs/remotes/origin/" + branch) != nil ? "origin/" + branch : branch
        }
        return count(base, "HEAD")
    }
}
