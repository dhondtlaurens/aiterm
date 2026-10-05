import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

struct RemoteResolverTests {
    private func makeRepo() throws -> String {
        let git = GitRunner()
        let dir = NSTemporaryDirectory() + "rr-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // git reports /private/var..., Foundation reports /var...; resolve once so the two agree.
        let repo = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        try git.run(["init", "--initial-branch=main", "-q", repo], in: "/")
        try git.run(["config", "user.email", "t@example.com"], in: repo)
        try git.run(["config", "user.name", "T"], in: repo)
        try git.run(["commit", "--allow-empty", "-q", "-m", "init"], in: repo)
        return repo
    }

    @Test func followsARemoteAddedAfterTheFirstLookup() throws {
        let repo = try makeRepo(), git = GitRunner(), resolver = RemoteResolver()
        #expect(resolver.remote(for: repo) == .remote(nil))
        try git.run(["remote", "add", "origin", "git@gitlab.example.com:group/app.git"], in: repo)
        #expect(resolver.remote(for: repo) == .remote("git@gitlab.example.com:group/app.git"))
    }

    @Test func followsARemoteUrlBeingChanged() throws {
        let repo = try makeRepo(), git = GitRunner(), resolver = RemoteResolver()
        try git.run(["remote", "add", "origin", "git@example.com:app.git"], in: repo)
        #expect(resolver.remote(for: repo) == .remote("git@example.com:app.git"))
        try git.run(["remote", "set-url", "origin", "git@gitlab.example.com:group/app.git"], in: repo)
        #expect(resolver.remote(for: repo) == .remote("git@gitlab.example.com:group/app.git"))
    }

    @Test func separatesADirectoryThatIsNotARepositoryFromOneWithoutARemote() throws {
        let dir = NSTemporaryDirectory() + "plain-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let resolver = RemoteResolver()
        #expect(resolver.remote(for: dir) == .notARepository)
        #expect(resolver.remote(for: "") == .notARepository)
        #expect(resolver.remote(for: "/definitely/not/here") == .notARepository)
        #expect(resolver.remote(for: try makeRepo()) == .remote(nil))
    }

    @Test func resolvesALinkedWorktreeToTheRepositoryRemote() throws {
        let repo = try makeRepo(), git = GitRunner(), resolver = RemoteResolver()
        try git.run(["remote", "add", "origin", "git@gitlab.example.com:group/app.git"], in: repo)
        let worktree = repo + "/.worktrees/feat"
        try git.run(["worktree", "add", "-q", "-b", "feat/y", worktree], in: repo)
        #expect(resolver.remote(for: worktree) == .remote("git@gitlab.example.com:group/app.git"))
    }

    /// The cache is revalidated by the config file's timestamp — the file `git remote add` rewrites
    /// — so a new remote is picked up without running git for every project on every refresh.
    @Test func cachedAnswerIsReusedUntilTheConfigChanges() throws {
        let repo = try makeRepo(), git = GitRunner()
        let counting = CountingGitRunner()
        let resolver = RemoteResolver(git: counting)
        #expect(resolver.remote(for: repo) == .remote(nil))
        let afterFirst = counting.calls
        #expect(resolver.remote(for: repo) == .remote(nil))
        #expect(counting.calls == afterFirst, "a second lookup must not shell out again")
        try git.run(["remote", "add", "origin", "git@gitlab.example.com:group/app.git"], in: repo)
        #expect(resolver.remote(for: repo) == .remote("git@gitlab.example.com:group/app.git"))
        #expect(counting.calls > afterFirst)
    }

    /// A folder that is not a repository is remembered for a while, so a project pointing at a
    /// plain directory cannot run git on every pass.
    @Test func negativeAnswersAreCachedAndReprobedAfterTheirWindow() throws {
        let dir = NSTemporaryDirectory() + "later-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let repo = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        let counting = CountingGitRunner()
        let clock = TestClock()
        let resolver = RemoteResolver(git: counting, now: { clock.now }, negativeTTL: 30)
        #expect(resolver.remote(for: repo) == .notARepository)
        let afterFirst = counting.calls
        #expect(resolver.remote(for: repo) == .notARepository)
        #expect(counting.calls == afterFirst, "a known non-repository must not shell out again")
        try GitRunner().run(["init", "--initial-branch=main", "-q", repo], in: "/")
        clock.advance(by: 31)
        #expect(resolver.remote(for: repo) == .remote(nil), "a folder that became a repository is re-probed")
    }
}

extension RemoteResolverTests {
    /// A timeout is git failing to answer, not git answering "no remote": it is not kept, so the
    /// remote shows up on the next lookup without anything rewriting `config`.
    @Test func aFailedLookupIsNotKeptAsNoRemote() throws {
        let repo = try makeRepo()
        try GitRunner().run(["remote", "add", "origin", "git@gitlab.example.com:group/app.git"], in: repo)
        let flaky = FlakyGitRunner(), resolver = RemoteResolver(git: flaky)
        flaky.failing = true
        #expect(resolver.remote(for: repo) == .unavailable)
        flaky.failing = false
        #expect(resolver.remote(for: repo) == .remote("git@gitlab.example.com:group/app.git"))
    }

    /// The same when only the read fails, `config` having been located: nothing is stored for the
    /// failed read, and the last answer stands meanwhile.
    @Test func aFailedReReadKeepsTheLastAnswerAndIsRetried() throws {
        let repo = try makeRepo(), flaky = FlakyGitRunner(), resolver = RemoteResolver(git: flaky)
        #expect(resolver.remote(for: repo) == .remote(nil))
        try GitRunner().run(["remote", "add", "origin", "git@example.com:app.git"], in: repo)
        flaky.failing = true
        #expect(resolver.remote(for: repo) == .remote(nil), "the last answer stands while git cannot be asked")
        flaky.failing = false
        #expect(resolver.remote(for: repo) == .remote("git@example.com:app.git"), "the failed re-read is retried, not remembered")
    }

    /// A failure while a folder is first looked up is not "this is not a repository" either,
    /// which would be remembered for the negative window.
    @Test func aFailedLookupOfARepositoryIsNotKeptAsNotOne() throws {
        let repo = try makeRepo(), flaky = FlakyGitRunner(), resolver = RemoteResolver(git: flaky)
        flaky.failing = true
        #expect(resolver.remote(for: repo) == .unavailable)
        flaky.failing = false
        #expect(resolver.remote(for: repo) == .remote(nil))
    }
}
