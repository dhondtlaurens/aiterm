import Foundation

/// Maps a directory to the branch checked out there, cheaply enough to be asked for every tab on
/// every daemon update.
///
/// A `git rev-parse` per tab every two seconds would be absurd, so the answer is cached against the
/// `HEAD` file git rewrites on every checkout (see ``WatchedFileCache``).
///
/// Thread-safe, and meant to be called off the main actor: every miss runs git.
public final class BranchResolver: Sendable {
    private let git: any GitRunning
    private let probe: RepositoryProbe
    private let cache: WatchedFileCache<String?>

    /// Resolvers given the same `probe` ask git where a directory's files are once between them.
    public init(git: any GitRunning, now: @escaping @Sendable () -> Date = Date.init, negativeTTL: TimeInterval = 30,
                probe: RepositoryProbe? = nil) {
        self.git = git
        self.probe = probe ?? RepositoryProbe(git: git, now: now, negativeTTL: negativeTTL)
        self.cache = WatchedFileCache(now: now, negativeTTL: negativeTTL)
    }

    /// The branch checked out in `cwd`, or `nil` when that is not a git checkout — or git could not
    /// be asked and nothing was known before. A failure is never kept; one after an answer leaves
    /// that answer standing until the next lookup.
    public func branch(for cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        let git = self.git, probe = self.probe
        do {
            switch try cache.answer(for: cwd, locate: { try Self.locate($0, probe: probe).map { [$0] } }, read: { try Self.read($0, head: $1[0], git: git) }) {
            case .notARepository: return nil
            case .found(let branch): return branch
            }
        } catch { return nil }
    }

    /// One pass over several directories, duplicates collapsed; directories that resolve to nothing
    /// are simply absent from the result.
    public func branches(for cwds: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for cwd in Set(cwds) where !cwd.isEmpty {
            if let branch = branch(for: cwd) { out[cwd] = branch }
        }
        return out
    }

    /// Forgets every directory not in `live`: the cwds and project paths the next pass asks about.
    /// The probe it shares is kept to the same set, the widest of the three resolvers'.
    public func retain(only live: Set<String>) {
        cache.retain(only: live)
        probe.retain(only: live)
    }

    /// The file a checkout rewrites: `HEAD`, or in a reftable repository the list of the stack
    /// that holds HEAD — there the `HEAD` file is a stub no checkout touches, and every ref update
    /// adds a table and rewrites that list instead. Its content says nothing `parseHead` reads, so
    /// such a repository's answer comes from git.
    private static func locate(_ cwd: String, probe: RepositoryProbe) throws -> String? {
        guard let found = try probe.locations(of: cwd) else { return nil }
        guard (try? String(contentsOfFile: found.head, encoding: .utf8)).map(isReftableStub) == true else { return found.head }
        return found.reftableList
    }

    /// What a reftable repository keeps in its `HEAD` file, for tools that look for one.
    static func isReftableStub(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == "ref: refs/heads/.invalid"
    }

    /// The branch name, or the short sha when HEAD is detached — a rebase or `git checkout <sha>`
    /// must not blank the row. The cache already found the `HEAD` file, and every checkout rewrites
    /// it, so it is read directly; only what `parseHead` cannot answer costs a git call. `nil` is
    /// git saying HEAD names nothing (a repository without a commit); a git that cannot be asked
    /// throws.
    static func read(_ cwd: String, head: String, git: any GitRunning) throws -> String? {
        if let text = try? String(contentsOfFile: head, encoding: .utf8), let answer = parseHead(text) { return answer }
        if let name = try git.ask(["symbolic-ref", "--short", "--quiet", "HEAD"], in: cwd, none: [1]), !name.isEmpty { return name }
        if let sha = try git.ask(["rev-parse", "--short", "HEAD"], in: cwd, none: [128]), !sha.isEmpty { return sha }
        return nil
    }

    /// `ref: refs/heads/<name>` is a branch; forty hex digits are a detached HEAD, shown as the
    /// seven-digit short sha. Anything else — a HEAD outside `refs/heads`, a SHA-256 repository, a
    /// reftable repository's stub — is left to git.
    static func parseHead(_ text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isReftableStub(line) { return nil }
        if line.hasPrefix("ref: refs/heads/") {
            let name = line.dropFirst("ref: refs/heads/".count)
            return name.isEmpty ? nil : String(name)
        }
        guard line.count == 40, line.allSatisfy(\.isHexDigit) else { return nil }
        return String(line.prefix(7))
    }
}
