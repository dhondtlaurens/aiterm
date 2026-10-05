import Foundation

public struct GitError: Error, Equatable, LocalizedError, CustomStringConvertible {
    public let args: [String], code: Int32, stderr: String
    public init(args: [String], code: Int32, stderr: String) { self.args = args; self.code = code; self.stderr = stderr }
    public var errorDescription: String? { description }
    public var description: String { stderr.isEmpty ? "Git exited with status \(code)." : stderr }

    /// Why git failed, in its own words: its `fatal:` and `error:` lines, else its last line. git
    /// narrates before it fails — `worktree add` opens with "Preparing worktree (…)" — so where
    /// there is room for only a few lines, the first few are the wrong ones. A failure line that ends
    /// in `:` introduces the files it is about, one per tab-indented line after it; the first few
    /// are kept on it (`…by merge: f, g`).
    public var reason: String {
        let raw = stderr.split(separator: "\n").map(String.init)
        var failures: [String] = []
        for (i, line) in raw.enumerated() {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("fatal:") || text.hasPrefix("error:") else { continue }
            failures.append(text.hasSuffix(":") ? text + Self.listed(raw[(i + 1)...]) : text)
        }
        let lines = raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return failures.isEmpty ? lines.last ?? description : failures.joined(separator: "\n")
    }

    /// The tab-indented lines at the start of `rest`, as ` a, b, c and 2 more`; `""` when there are none.
    private static func listed(_ rest: ArraySlice<String>) -> String {
        let items = rest.prefix { $0.hasPrefix("\t") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !items.isEmpty else { return "" }
        return " " + items.prefix(3).joined(separator: ", ") + (items.count > 3 ? " and \(items.count - 3) more" : "")
    }

    /// `git worktree remove` refusing a checkout with uncommitted or untracked files — the one
    /// refusal that `--force` answers, after asking.
    public var refusedForUnsavedWork: Bool {
        args.starts(with: ["worktree", "remove"]) && stderr.lowercased().contains("modified or untracked files")
    }

    /// `reason` for a git failure, the description for anything else.
    public static func reason(of error: Error) -> String { (error as? GitError)?.reason ?? "\(error)" }

    /// `reason(of:)` as a sentence to show beside AiTerm's own: git's `fatal:` and `error:`
    /// prefixes dropped, each line capitalised and ended with a full stop — unless it ends in
    /// punctuation already, a `:` included — joined into one line.
    public static func sentence(of error: Error) -> String {
        reason(of: error).split(separator: "\n").map { line -> String in
            var text = String(line)
            for prefix in ["fatal:", "error:"] where text.hasPrefix(prefix) {
                text = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            }
            text = text.prefix(1).uppercased() + text.dropFirst()
            return text.last.map { ".!?:".contains($0) } == true ? text : text + "."
        }.joined(separator: " ")
    }
}

/// Not `final`: `BranchResolverTests` subclasses it to count how often git is actually run, which
/// is the only way to prove the resolver's cache is doing its job.
///
/// Every command has a deadline, because git can wait on something that never answers — a remote,
/// or an `ssh` asking for a passphrase no one can type — and it is always run on a thread someone
/// is waiting for. A command that runs out of time throws a `GitError` that says so.
///
/// Unchecked only because the class is open to subclassing: its stored properties are immutable
/// `let`s, and each test subclass guards the counters it adds with a lock.
public class GitRunner: @unchecked Sendable {
    /// Reading refs, the index or config: well under a second, even in a large repository.
    public static let localTimeout: TimeInterval = 10
    /// Talking to a remote (`runRemote`).
    public static let remoteTimeout: TimeInterval = 30
    /// `worktree add` and `remove`: a checkout runs hooks and filters (LFS downloads), and a forced
    /// removal deletes whatever the task left, `node_modules` included. Killing either halfway
    /// leaves a worse mess than waiting. The `lock` and `unlock` around a removal too: they are
    /// quick, but tripped the local deadline under load.
    public static let checkoutTimeout: TimeInterval = 300

    /// Makes git abandon an HTTP transfer slower than 1 KB/s for 10 s, so a stalled fetch ends
    /// with git's own error well before `remoteTimeout` kills it.
    static let stallGuard = ["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=10"]

    let git: String
    /// Set over the inherited environment for every command. The tests' fixtures use it to run git
    /// without the developer's own configuration.
    let environment: [String: String]
    public init(git: String = "/usr/bin/git", environment: [String: String] = [:]) {
        self.git = git; self.environment = environment
    }

    @discardableResult
    public func run(_ args: [String], in dir: String, timeout: TimeInterval = GitRunner.localTimeout) throws -> String {
        try run(args, in: dir, timeout: timeout, environment: [:])
    }

    /// `run` with `extra` set for this one command as well. A subclass that overrides `run` does not
    /// see these calls.
    @discardableResult
    public func run(_ args: [String], in dir: String, timeout: TimeInterval, environment extra: [String: String]) throws -> String {
        var env = ProcessRunner.inheritedEnvironment.merging(environment) { $1 }.merging(extra) { $1 }
        env["GIT_OPTIONAL_LOCKS"] = "0"; env["GIT_TERMINAL_PROMPT"] = "0"
        // Some callers match git's English wording in stderr (`GitError.refusedForUnsavedWork`, "not
        // fully merged"), and a translated git — Homebrew's, under a nl or fr locale — would not say it.
        env["LC_ALL"] = "C"; env["LANGUAGE"] = "C"
        // Process.currentDirectoryURL can fall back when a checkout disappeared.
        // Git must itself validate the directory before doing anything to a repository.
        let result = try ProcessRunner.run(URL(fileURLWithPath: git), ["-C", dir] + args, environment: env,
                                           in: URL(fileURLWithPath: dir), timeout: timeout)
        if result.timedOut {
            throw GitError(args: args, code: result.status,
                           stderr: "\(Self.command(args)) timed out after \(String(format: "%g", timeout)) s")
        }
        guard result.status == 0 else {
            throw GitError(args: args, code: result.status, stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `run` for a command that talks to a remote — `fetch`, `ls-remote` — with the remote
    /// deadline and the stall guard.
    @discardableResult
    public func runRemote(_ args: [String], in dir: String) throws -> String {
        try run(Self.stallGuard + args, in: dir, timeout: Self.remoteTimeout)
    }

    /// How a person would name what `args` runs: `git fetch`, `git worktree add`, past any `-c`.
    private static func command(_ args: [String]) -> String {
        var rest = args[...]
        while let first = rest.first, first.hasPrefix("-") { rest = rest.dropFirst(first == "-c" ? 2 : 1) }
        let words = rest.prefix(["worktree", "remote"].contains(rest.first) ? 2 : 1)
        return (["git"] + words).joined(separator: " ")
    }
}

extension GitRunner {
    /// `run` for a question git can answer "no" to by exiting with a status of its own — `1` for
    /// `rev-parse --verify --quiet` and `symbolic-ref --quiet`, `2` for `remote get-url` of a remote
    /// that does not exist, `128` for a `fatal:`: `nil` for one of `none`. Any other failure — a
    /// timeout, git not starting, a status nothing expects — says nothing about the answer and is
    /// thrown, so it is never mistaken for one.
    func ask(_ args: [String], in dir: String, none: Set<Int32>) throws -> String? {
        do { return try run(args, in: dir) }
        catch let error as GitError where none.contains(error.code) { return nil }
    }
}
