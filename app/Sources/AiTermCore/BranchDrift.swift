import Foundation

/// A worker that committed off its task branch: its worktree's HEAD moved to another branch or came
/// loose from one, or its last message names a commit the task branch doesn't hold. AiTerm reads only
/// the task branch, so that work would otherwise go unseen until the runtime ran out. Advisory: it is
/// shown in `run_status`, and the Operator decides what to do with it.
public struct BranchDrift: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case head, lastMessage }
    public var source: Source
    /// The branch the commit was found on: HEAD's branch, or one holding the commit the message named.
    /// Nil for a detached HEAD, or a commit on no branch.
    public var branch: String?
    /// The commit found: HEAD's, or the SHA as the message wrote it.
    public var sha: String?
    /// What AiTerm found, in one sentence.
    public var found: String

    public init(source: Source, branch: String?, sha: String?, found: String) {
        self.source = source; self.branch = branch; self.sha = sha; self.found = found
    }

    /// The worktree's HEAD as git reads it: its branch, nil when detached, and its commit.
    public struct Head: Equatable, Sendable {
        public var branch: String?, sha: String?
        public init(branch: String?, sha: String?) { self.branch = branch; self.sha = sha }
    }

    /// A SHA the worker's last message names: the commit it is in the repository, if it is one there,
    /// whether the task branch holds it, and the branches that do.
    public struct Named: Equatable, Sendable {
        public var text: String, commit: String?, onTaskBranch: Bool, branches: [String]
        public init(text: String, commit: String?, onTaskBranch: Bool, branches: [String] = []) {
            self.text = text; self.commit = commit; self.onTaskBranch = onTaskBranch; self.branches = branches
        }
    }

    /// The words of `message` that may be a commit's SHA: 7 to 40 lowercase hex characters, at least one a
    /// digit, standing alone. A word of letters alone (`defaced`) or a piece of a UUID or a hyphenated id is
    /// not one. One of digits alone may be a number: it counts only once git finds the commit (`isNumber`).
    public static func shaCandidates(in message: String) -> [String] {
        let words = message.split { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        var seen: Set<String> = []
        return words.map(String.init).filter { word in
            (7...40).contains(word.count) && word.allSatisfy { $0.isHexDigit && !$0.isUppercase }
                && word.contains(where: \.isNumber) && seen.insert(word).inserted
        }
    }

    /// A candidate of digits alone, which reads as a number as well as a SHA.
    public static func isNumber(_ candidate: String) -> Bool { candidate.allSatisfy(\.isNumber) }

    /// What AiTerm finds of `taskBranch`'s worker, its HEAD first. `head` nil is a worktree git couldn't
    /// read, and `named` nil a last message not read now (the worker still at work): each says nothing,
    /// so what `previous` found from it is kept until it is read again.
    public static func find(taskBranch: String, head: Head?, named: [Named]?, previous: BranchDrift?) -> BranchDrift? {
        let headDrift = head.map { headDrift($0, taskBranch: taskBranch) } ?? (previous?.source == .head ? previous : nil)
        let messageDrift = named.map { messageDrift($0, taskBranch: taskBranch) } ?? (previous?.source == .lastMessage ? previous : nil)
        return headDrift ?? messageDrift
    }

    private static func headDrift(_ head: Head, taskBranch: String) -> BranchDrift? {
        guard head.branch != taskBranch else { return nil }
        if let branch = head.branch {
            return BranchDrift(source: .head, branch: branch, sha: head.sha,
                               found: "Its worktree is on branch \(branch), not on its task branch \(taskBranch).")
        }
        let at = head.sha.map { " at \($0.prefix(7))" } ?? ""
        return BranchDrift(source: .head, branch: nil, sha: head.sha, found: "Its worktree's HEAD is detached\(at), off its task branch \(taskBranch).")
    }

    private static func messageDrift(_ named: [Named], taskBranch: String) -> BranchDrift? {
        guard let off = named.first(where: { !$0.onTaskBranch }) else { return nil }
        let found = off.commit == nil
            ? "Its last message names \(off.text), which isn't a commit in this repository, so not on its task branch \(taskBranch)."
            : "Its last message names \(off.text), which isn't on its task branch \(taskBranch)"
              + (off.branches.isEmpty ? "." : ": it is on \(off.branches.joined(separator: ", ")).")
        return BranchDrift(source: .lastMessage, branch: off.branches.first, sha: off.text, found: found)
    }
}
