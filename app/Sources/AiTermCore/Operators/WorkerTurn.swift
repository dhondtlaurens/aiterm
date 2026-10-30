import Foundation
import CryptoKit

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

    /// Dirt proves a change only against the content recorded at acceptance. Older acceptances have no such
    /// baseline: only a different HEAD proves they moved. Failed reads supply no evidence of a change.
    public static func changedAfterAcceptance(head: String?, accepted: String?, fingerprint: String? = nil,
                                              acceptedFingerprint: String? = nil) -> Bool {
        guard let accepted, !accepted.isEmpty else { return false }
        if let fingerprint, let acceptedFingerprint, fingerprint != acceptedFingerprint { return true }
        guard let head, !head.isEmpty else { return false }
        return !OperatedTransitions.sameCommit(head, accepted)
    }
}

public extension Repository {
    /// Uncommitted content, independent of whether it is staged. NUL records preserve unusual filenames;
    /// status v2 starts with a record type, so GitRunner's whitespace trimming cannot eat a filename.
    /// Read symlink targets, never the files they point at. Nothing is written to Git's index or objects.
    func worktreeFingerprint() throws -> String {
        let status = try git.run(["status", "--porcelain=v2", "-z", "--untracked-files=all", "--no-renames"], in: path)
        let names = status.split(separator: "\0").compactMap { record -> String? in
            if record.hasPrefix("? ") { return String(record.dropFirst(2)) }
            let spaces = record.hasPrefix("1 ") ? 8 : record.hasPrefix("u ") ? 10 : 0
            guard spaces > 0 else { return nil }
            return record.split(separator: " ", maxSplits: spaces, omittingEmptySubsequences: false).last.map(String.init)
        }
        var fingerprint = SHA256()
        func append(_ text: String) {
            fingerprint.update(data: Data(text.utf8))
            fingerprint.update(data: Data([0]))
        }
        for name in Set(names).sorted() {
            append(name)
            let file = URL(fileURLWithPath: path).appendingPathComponent(name)
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                append("deleted"); append(""); continue
            }
            var content = SHA256()
            switch attributes[.type] as? FileAttributeType {
            case .typeSymbolicLink:
                append("symlink")
                content.update(data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: file.path).utf8))
            case .typeRegular:
                let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
                append(mode & 0o111 == 0 ? "file" : "executable")
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { content.update(data: data) }
            case .typeDirectory:
                // Gitlinks and nested repositories are directories in status. Their own HEAD and content
                // matter, while an uninitialized submodule has no checkout content to fingerprint.
                append("repository")
                if FileManager.default.fileExists(atPath: file.appendingPathComponent(".git").path) {
                    let nested = Repository(file.path, git: git)
                    content.update(data: Data(try git.run(["rev-parse", "HEAD"], in: file.path).utf8))
                    content.update(data: Data(try nested.worktreeFingerprint().utf8))
                }
            default: throw CocoaError(.fileReadUnknown)
            }
            append(content.finalize().map { String(format: "%02x", $0) }.joined())
        }
        return fingerprint.finalize().map { String(format: "%02x", $0) }.joined()
    }

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
