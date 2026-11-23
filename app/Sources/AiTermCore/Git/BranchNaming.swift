import Foundation

/// The names AiTerm gives what it creates: a task's branch from its ticket and title, and the
/// worktree directory a task's or review's branch is checked out in.
public enum BranchNaming {
    /// `text` lowercased to ASCII letters and digits, every run of anything else one `-`, at most
    /// 48 characters.
    public static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = "", lastDash = true
        for ch in lowered {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 48 { out = String(out.prefix(48)); while out.hasSuffix("-") { out.removeLast() } }
        return out
    }

    /// The part of a task branch after its type: the ticket key, then the slugged summary. A summary
    /// that opens with its own key (`FE-1783 Dependency updates`, as Jira titles often do) is not
    /// said twice.
    static func branchSlug(key: String?, summary: String) -> String {
        [key?.lowercased(), slug(withoutLeading(key, in: summary))].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "-")
    }

    /// `summary` less a leading copy of `key`: any case, and followed by a space, `:`, `-` or `–`
    /// (or by nothing). `FE-17` does not open `FE-178 Vue`.
    private static func withoutLeading(_ key: String?, in summary: String) -> String {
        guard let key, !key.isEmpty, summary.lowercased().hasPrefix(key.lowercased()) else { return summary }
        let rest = summary.dropFirst(key.count)
        guard let next = rest.first else { return "" }
        return " :-–".contains(next) ? String(rest) : summary
    }

    /// A scheduled run's branch: `feat/` and the signal name's slug, cut so that the suffix
    /// `-<first 6 of the signal id>-yyyymmdd-HHmm` is never cut, here or in the worktree directory (`worktreeSlug`),
    /// which both stop at 48 characters. The id keeps two signals of one name apart; the whole time keeps each run of one
    /// signal on a branch of its own. The time is UTC, so a change of the Mac's time zone never repeats one.
    public static func runBranch(signalName: String, signal: UUID, at: Date) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        let suffix = String(signal.uuidString.lowercased().prefix(6)) + "-"
            + String(format: "%04d%02d%02d-%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
        var name = String(slug(signalName).prefix(48 - suffix.count - 1))
        while name.hasSuffix("-") { name.removeLast() }
        return BranchType.feat.rawValue + "/" + (name.isEmpty ? "run" : name) + "-" + suffix
    }

    /// The worktree directory for `branch`, less its type: `feat/login` works in `.worktrees/login`.
    public static func worktreeSlug(branch: String) -> String {
        let withoutPrefix = branch.split(separator: "/").dropFirst().joined(separator: "-")
        var slug = Self.slug(withoutPrefix.isEmpty ? branch : withoutPrefix)
        // `slug` keeps ASCII letters and digits only, so a branch like `feat/日本語` or `feat/--` can
        // slug to nothing at all — and an empty slug would make the worktree path the `.worktrees`
        // directory itself, which git would then be asked to create a checkout in. Fall back to the
        // whole branch name, then to a random but valid directory name.
        if slug.isEmpty { slug = Self.slug(branch) }
        if slug.isEmpty { slug = "task-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased() }
        return slug
    }

    /// A review's worktree directory, prefixed so a review and a task on related branches cannot
    /// collide on a path and so the directory says which it is.
    public static func reviewSlug(branch: String) -> String { "review-" + worktreeSlug(branch: branch) }

    /// `slug`, else the first of `slug-2`, `slug-3`… that is not already in `repo`'s worktree
    /// directory, nor `reserved` — the folders the project's archived rows come back to — nor
    /// `registered`, the folders git lists a worktree at (`Repository.registeredWorktreeFolders`): a
    /// checkout deleted outside AiTerm leaves git's record of it, locked, and git refuses its folder to
    /// a new worktree. Dropping the type makes `feat/login` and `fix/login` want the same one. Create
    /// and the sheets' preview both ask this, so the directory named is the one made.
    public static func unused(_ slug: String, in repo: String, reserved: Set<String> = [], registered: Set<String> = []) -> String {
        let directory = repo + "/" + Worktree.directoryName + "/"
        var candidate = slug, n = 1
        while reserved.contains(candidate) || registered.contains(candidate) || FileManager.default.fileExists(atPath: directory + candidate) {
            n += 1; candidate = "\(slug)-\(n)"
        }
        return candidate
    }

    /// Whether git takes `name` as a branch name.
    static func isValid(_ name: String, git: any GitRunning) throws -> Bool {
        try git.ask(["check-ref-format", "--branch", name], in: "/", none: [128]) != nil
    }
}
