import Foundation
import Testing
@testable import AiTermCore

struct BranchResolverTests {
    private func makeRepo(refFormat: String = "files") throws -> String {
        let git = GitRunner()
        let dir = NSTemporaryDirectory() + "br-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // git reports /private/var..., Foundation reports /var...; resolve once so the two agree.
        let repo = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        try git.run(["init", "--initial-branch=main", "--ref-format=" + refFormat, "-q", repo], in: "/")
        try git.run(["config", "user.email", "t@example.com"], in: repo)
        try git.run(["config", "user.name", "T"], in: repo)
        try git.run(["commit", "--allow-empty", "-q", "-m", "init"], in: repo)
        return repo
    }

    @Test func resolvesTheCheckedOutBranchAndFollowsACheckout() throws {
        let repo = try makeRepo(), git = GitRunner(), resolver = BranchResolver()
        #expect(resolver.branch(for: repo) == "main")
        try git.run(["checkout", "-q", "-b", "feat/x"], in: repo)
        #expect(resolver.branch(for: repo) == "feat/x")
    }

    @Test func resolvesALinkedWorktreeToItsOwnBranch() throws {
        let repo = try makeRepo(), git = GitRunner(), resolver = BranchResolver()
        let worktree = repo + "/.worktrees/feat"
        try git.run(["worktree", "add", "-q", "-b", "feat/y", worktree], in: repo)
        #expect(resolver.branch(for: worktree) == "feat/y")
        #expect(resolver.branch(for: repo) == "main")
    }

    @Test func reportsTheShortShaWhenHeadIsDetached() throws {
        let repo = try makeRepo(), git = GitRunner(), resolver = BranchResolver()
        let sha = try git.run(["rev-parse", "--short", "HEAD"], in: repo)
        try git.run(["checkout", "-q", "--detach"], in: repo)
        #expect(resolver.branch(for: repo) == sha)
    }

    /// What `read` asks git when `HEAD` itself does not say: a detached HEAD is `symbolic-ref`'s
    /// exit 1, and the answer is the short sha; a repository without a commit still names its
    /// branch. Neither throws. A SHA-256 repository's `HEAD` is 64 hex digits, which `parseHead`
    /// leaves to git; a reftable one's `HEAD` file is a stub.
    @Test func headsGitIsAskedAboutResolveWithoutThrowing() throws {
        let git = GitRunner()
        let dir = NSTemporaryDirectory() + "br-sha256-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try git.run(["init", "--initial-branch=main", "--object-format=sha256", "-q", dir], in: "/")
        let repo = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        let head = repo + "/.git/HEAD"
        #expect(try BranchResolver.read(repo, head: head, git: git) == "main", "unborn, HEAD still names its branch")
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], in: repo)
        try git.run(["checkout", "-q", "--detach"], in: repo)
        #expect(BranchResolver.parseHead(try String(contentsOfFile: head, encoding: .utf8)) == nil)
        let sha = try git.run(["rev-parse", "--short", "HEAD"], in: repo)
        #expect(try BranchResolver.read(repo, head: head, git: git) == sha)

        let unborn = try makeRepo(refFormat: "reftable"), stub = unborn + "/.git/HEAD"
        try git.run(["update-ref", "-d", "refs/heads/main"], in: unborn)
        #expect(try BranchResolver.read(unborn, head: stub, git: git) == "main", "no commit yet, and the branch is still named")
    }

    @Test func returnsNilOutsideARepository() throws {
        let dir = NSTemporaryDirectory() + "plain-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        #expect(BranchResolver().branch(for: dir) == nil)
        #expect(BranchResolver().branch(for: "") == nil)
        #expect(BranchResolver().branch(for: "/definitely/not/here") == nil)
    }

    @Test func batchLookupSkipsWhatItCannotResolve() throws {
        let repo = try makeRepo()
        let map = BranchResolver().branches(for: [repo, "", "/definitely/not/here", repo])
        #expect(map == [repo: "main"])
    }

    /// The cache is revalidated by HEAD's timestamp, so a checkout between two calls is picked up
    /// without re-running git for every tab on every update.
    @Test func cachedAnswerIsReusedUntilHeadChanges() throws {
        let repo = try makeRepo(), git = GitRunner()
        let counting = CountingGitRunner()
        let resolver = BranchResolver(git: counting)
        #expect(resolver.branch(for: repo) == "main")
        let afterFirst = counting.calls
        #expect(resolver.branch(for: repo) == "main")
        #expect(counting.calls == afterFirst, "a second lookup must not shell out again")
        try git.run(["checkout", "-q", "-b", "feat/z"], in: repo)
        #expect(resolver.branch(for: repo) == "feat/z")
        #expect(counting.calls == afterFirst, "a changed HEAD is read from the file the cache watches, not from git")
        try git.run(["checkout", "-q", "--detach"], in: repo)
        #expect(resolver.branch(for: repo) == String(try git.run(["rev-parse", "HEAD"], in: repo).prefix(7)))
        #expect(counting.calls == afterFirst)
    }

    /// Finding HEAD is one git call; what it says is then read from the file itself.
    @Test func theFirstLookupRunsGitOnlyToFindHead() throws {
        let repo = try makeRepo(), counting = CountingGitRunner()
        #expect(BranchResolver(git: counting).branch(for: repo) == "main")
        #expect(counting.calls == 1)
    }

    /// A reftable repository's HEAD file is a stub, `ref: refs/heads/.invalid`, that no checkout
    /// rewrites: its refs, HEAD's target among them, live in tables the stack's list names.
    @Test func aReftableRepositoryIsResolvedAndFollowsACheckout() throws {
        let repo = try makeRepo(refFormat: "reftable"), git = GitRunner(), resolver = BranchResolver()
        #expect(resolver.branch(for: repo) == "main")
        try git.run(["checkout", "-q", "-b", "feat/x"], in: repo)
        #expect(resolver.branch(for: repo) == "feat/x")

        let worktree = repo + "/.worktrees/feat"
        try git.run(["worktree", "add", "-q", "-b", "feat/y", worktree], in: repo)
        #expect(resolver.branch(for: worktree) == "feat/y")
        try git.run(["checkout", "-q", "-b", "feat/z"], in: worktree)
        #expect(resolver.branch(for: worktree) == "feat/z")
        #expect(resolver.branch(for: repo) == "feat/x")
    }

    @Test func headIsReadAsABranchOrAShortSha() {
        #expect(BranchResolver.parseHead("ref: refs/heads/feat/x\n") == "feat/x")
        #expect(BranchResolver.parseHead("0123456789abcdef0123456789abcdef01234567\n") == "0123456")
        // Anything else — a HEAD pointing outside refs/heads, a SHA-256 repository — is git's to answer.
        #expect(BranchResolver.parseHead("ref: refs/remotes/origin/main\n") == nil)
        #expect(BranchResolver.parseHead(String(repeating: "a", count: 64)) == nil)
        #expect(BranchResolver.parseHead("") == nil)
        #expect(BranchResolver.parseHead("ref: refs/heads/.invalid\n") == nil, "a reftable repository's stub")
    }
}

extension BranchResolverTests {
    /// Failing to find `HEAD` is not "not a repository", which would be remembered for the negative
    /// window and leave the row without a branch.
    @Test func aFailedLookupIsNotKeptAsNotARepository() throws {
        let repo = try makeRepo(), flaky = FlakyGitRunner(), resolver = BranchResolver(git: flaky)
        flaky.failing = true
        #expect(resolver.branch(for: repo) == nil)
        flaky.failing = false
        #expect(resolver.branch(for: repo) == "main")
    }

    /// A reftable repository's branch comes from git. When git times out on a checkout, the row
    /// keeps the branch it had rather than caching "none" until HEAD moves again.
    @Test func aFailedReadKeepsTheLastBranchAndIsRetried() throws {
        let repo = try makeRepo(refFormat: "reftable"), git = GitRunner()
        let flaky = FlakyGitRunner(), resolver = BranchResolver(git: flaky)
        #expect(resolver.branch(for: repo) == "main")
        try git.run(["checkout", "-q", "-b", "feat/x"], in: repo)
        flaky.failing = true
        #expect(resolver.branch(for: repo) == "main", "the last answer stands while git cannot be asked")
        flaky.failing = false
        #expect(resolver.branch(for: repo) == "feat/x")
    }
}

/// A `GitRunner` that counts how often it is actually asked to run something.
///
/// Unchecked because its stored `var`s are mutable: every access holds `lock`.
private final class CountingGitRunner: GitRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }

    override func run(_ args: [String], in dir: String, timeout: TimeInterval = GitRunner.localTimeout) throws -> String {
        lock.lock(); _calls += 1; lock.unlock()
        return try super.run(args, in: dir, timeout: timeout)
    }
}
