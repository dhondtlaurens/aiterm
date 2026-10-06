import Foundation

/// A repository's `info/exclude`, where AiTerm keeps its own folders — `.worktrees/` in a project,
/// `.aiterm/` in a worktree — out of `git status` without touching the project's `.gitignore`.
public enum ExcludeFile {
    /// The `info/exclude` file that applies to `path`, whether `path` is an ordinary checkout or a
    /// linked worktree. Asking git (`rev-parse --git-path info/exclude`) instead of assuming
    /// `<path>/.git/info/exclude` is what makes the linked-worktree case work: there `.git` is a
    /// *file* pointing at the common dir, so the assumed path is not a directory we may create.
    /// git answers with an absolute path from inside a linked worktree and a relative one from a
    /// normal checkout; both are handled. `nil` means "not a git repository" (or git is missing).
    public static func url(forWorktreeOrRepo path: String, git: any GitRunning) -> URL? {
        guard let answer = try? git.run(["rev-parse", "--git-path", "info/exclude"], in: path), !answer.isEmpty else { return nil }
        return URL(fileURLWithPath: answer.hasPrefix("/") ? answer : path + "/" + answer)
    }

    /// Appends `pattern` to an exclude file, creating the containing directory and the file if
    /// needed. Idempotent: a line that already matches exactly is left alone.
    public static func append(_ pattern: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard !current.split(separator: "\n").contains(where: { $0 == pattern }) else { return }
        try (current + (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + pattern + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
