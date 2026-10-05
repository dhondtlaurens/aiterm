import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The default branch the project menu's "Pull main" names, read on every refresh pass.
final class DefaultBranchResolverTests {
    let git = GitRunner.hermetic()
    /// Every folder a test made, removed with it.
    private var made: [String] = []
    deinit { for dir in made { try? FileManager.default.removeItem(atPath: dir) } }

    /// A new folder under the temporary directory, resolved: git reports /private/var..., Foundation
    /// reports /var..., so resolve once and the two agree.
    private func folder(_ prefix: String) throws -> String {
        let dir = NSTemporaryDirectory() + prefix + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let resolved = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        made.append(resolved)
        return resolved
    }

    private func makeRepo(branch: String = "main", refFormat: String? = nil) throws -> String {
        let repo = try folder("dbr-")
        try git.run(["init", "--initial-branch=\(branch)", "-q"] + (refFormat.map { ["--ref-format=\($0)"] } ?? []) + [repo], in: "/")
        try git.run(["config", "user.email", "t@example.com"], in: repo)
        try git.run(["config", "user.name", "T"], in: repo)
        try git.run(["commit", "--allow-empty", "-q", "-m", "init"], in: repo)
        return repo
    }

    /// A clone of `origin`, so `origin/HEAD` names origin's default.
    private func clone(_ origin: String, refFormat: String? = nil) throws -> String {
        let dir = try folder("dbr-clone-") + "/checkout"
        try git.run(["clone", "-q"] + (refFormat.map { ["--ref-format=\($0)"] } ?? []) + [origin, dir], in: "/")
        return dir
    }

    @Test func namesOriginsDefaultBranch() throws {
        let checkout = try clone(try makeRepo(branch: "develop"))
        #expect(DefaultBranchResolver(git: git).defaultBranch(for: checkout) == "develop")
    }

    @Test func resolvesALinkedWorktreeToTheRepositorysDefault() throws {
        let checkout = try clone(try makeRepo(branch: "develop"))
        let worktree = checkout + "/.worktrees/feat"
        try git.run(["worktree", "add", "-q", "-b", "feat/y", worktree], in: checkout)
        #expect(DefaultBranchResolver(git: git).defaultBranch(for: worktree) == "develop")
    }

    @Test func aDirectoryThatIsNotARepositoryHasNone() throws {
        let dir = try folder("plain-")
        let resolver = DefaultBranchResolver(git: git)
        #expect(resolver.defaultBranch(for: dir) == nil)
        #expect(resolver.defaultBranch(for: "") == nil)
        #expect(resolver.defaultBranch(for: "/definitely/not/here") == nil)
    }

    /// The answer is kept against the refs it is read from, so an unchanged repository costs a
    /// `stat` per ref rather than a git call — and `git remote set-head` is picked up all the same.
    @Test func cachedAnswerIsReusedUntilOriginsHeadMoves() throws {
        let origin = try makeRepo(branch: "main"), checkout = try clone(origin)
        let counting = CountingGitRunner()
        let resolver = DefaultBranchResolver(git: counting)
        #expect(resolver.defaultBranch(for: checkout) == "main")
        let afterFirst = counting.calls
        #expect(resolver.defaultBranch(for: checkout) == "main")
        #expect(counting.calls == afterFirst, "a second lookup must not shell out again")

        try git.run(["branch", "-q", "trunk"], in: origin)
        try git.run(["fetch", "-q", "origin"], in: checkout)
        try git.run(["remote", "set-head", "origin", "trunk"], in: checkout)
        #expect(resolver.defaultBranch(for: checkout) == "trunk")
    }

    /// A reftable repository keeps no ref in a file of its own and has no `packed-refs`: every
    /// update rewrites `reftable/tables.list` instead, so that is what is watched there.
    @Test func aReftableRepositoryIsReadAgainWhenOriginsHeadMoves() throws {
        let origin = try makeRepo(branch: "main", refFormat: "reftable"), checkout = try clone(origin, refFormat: "reftable")
        let resolver = DefaultBranchResolver(git: git)
        #expect(resolver.defaultBranch(for: checkout) == "main")
        try git.run(["branch", "-q", "trunk"], in: origin)
        try git.run(["fetch", "-q", "origin"], in: checkout)
        try git.run(["remote", "set-head", "origin", "trunk"], in: checkout)
        #expect(resolver.defaultBranch(for: checkout) == "trunk")
    }

    /// A repository whose refs are none of the watched ones — no origin, a default of `develop` —
    /// is still watched through its `config`, so its going away is noticed.
    @Test func aRepositoryThatWentAwayIsProbedAgain() throws {
        let repo = try makeRepo(branch: "develop")
        let resolver = DefaultBranchResolver(git: git)
        #expect(resolver.defaultBranch(for: repo) != nil)
        try FileManager.default.removeItem(atPath: repo + "/.git")
        #expect(resolver.defaultBranch(for: repo) == nil)
    }

    /// A folder that is not a repository is remembered for a while, so a project pointing at a
    /// plain directory cannot run git on every pass.
    @Test func negativeAnswersAreCachedAndReprobedAfterTheirWindow() throws {
        let repo = try folder("later-")
        let counting = CountingGitRunner()
        let clock = TestClock()
        let resolver = DefaultBranchResolver(git: counting, now: { clock.now }, negativeTTL: 30)
        #expect(resolver.defaultBranch(for: repo) == nil)
        let afterFirst = counting.calls
        #expect(resolver.defaultBranch(for: repo) == nil)
        #expect(counting.calls == afterFirst, "a known non-repository must not shell out again")
        try git.run(["init", "--initial-branch=master", "-q", repo], in: "/")
        try git.run(["-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "--allow-empty", "-q", "-m", "init"], in: repo)
        clock.advance(by: 31)
        #expect(resolver.defaultBranch(for: repo) == "master", "a folder that became a repository is re-probed")
    }
}

extension DefaultBranchResolverTests {
    /// A timeout is not "this repository has no usable default" and is not kept: the name shows up
    /// on the next lookup, rather than the fallback standing until a ref moves.
    @Test func aFailedLookupIsNotKept() throws {
        let checkout = try clone(try makeRepo(branch: "develop"))
        let flaky = FlakyGitRunner(), resolver = DefaultBranchResolver(git: flaky)
        flaky.failing = true
        #expect(resolver.defaultBranch(for: checkout) == nil)
        flaky.failing = false
        #expect(resolver.defaultBranch(for: checkout) == "develop")
    }

    /// While git cannot be asked, the name the menu already shows stays, and a ref that moved
    /// meanwhile is read as soon as it can.
    @Test func theLastAnswerStandsWhileGitCannotBeAsked() throws {
        let checkout = try clone(try makeRepo(branch: "develop"))
        let flaky = FlakyGitRunner(), resolver = DefaultBranchResolver(git: flaky)
        #expect(resolver.defaultBranch(for: checkout) == "develop")
        try git.run(["branch", "-q", "main"], in: checkout)
        try git.run(["remote", "set-head", "origin", "-d"], in: checkout)
        flaky.failing = true
        #expect(resolver.defaultBranch(for: checkout) == "develop")
        flaky.failing = false
        #expect(resolver.defaultBranch(for: checkout) == "main", "origin/HEAD is gone, so the usual names decide: local main")
    }
}
