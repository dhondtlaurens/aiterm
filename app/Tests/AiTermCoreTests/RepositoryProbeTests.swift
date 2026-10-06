import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The one `rev-parse` that names the files the three resolvers watch.
@Suite(.blocking) struct RepositoryProbeTests {
    private let git = GitRunner.hermetic()

    /// The path git reports, which has no symlink in it: `/private/var/…` for the temporary directory.
    private func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func probes(_ runner: RecordingGitRunner) -> Int {
        runner.calls.filter { $0.args.contains("--git-common-dir") }.count
    }

    @Test func namesTheFilesOfAnOrdinaryCheckout() throws {
        let repo = try GitFixture.makeRepo(prefix: "probe-", git: git)
        let found = try #require(try RepositoryProbe(git: git).locations(of: repo)), root = real(repo)
        #expect(found == RepositoryProbe.Locations(head: root + "/.git/HEAD", reftableList: root + "/.git/reftable/tables.list",
                                                   config: root + "/.git/config", commonDirectory: root + "/.git"))
    }

    /// From a linked worktree `HEAD` and the reftable stack are the worktree's own, and the config
    /// and the refs the repository's.
    @Test func namesTheFilesOfALinkedWorktree() throws {
        let repo = try GitFixture.makeRepo(prefix: "probe-", git: git)
        let worktree = repo + "/.worktrees/feat"
        try git.run(["worktree", "add", "-q", "-b", "feat/x", worktree], in: repo)
        let found = try #require(try RepositoryProbe(git: git).locations(of: worktree)), root = real(repo)
        #expect(found.head == root + "/.git/worktrees/feat/HEAD")
        #expect(found.reftableList == root + "/.git/worktrees/feat/reftable/tables.list")
        #expect(found.config == root + "/.git/config")
        #expect(found.commonDirectory == root + "/.git")
    }

    /// The three resolvers asking about one project spawn one `rev-parse` between them where each
    /// used to spawn its own, and the answers are the ones they gave.
    @Test func theThreeResolversShareOneSpawn() throws {
        let repo = try GitFixture.makeRepo(prefix: "probe-", git: git)
        try git.run(["remote", "add", "origin", "git@example.com:app.git"], in: repo)
        func spawns(shared: Bool) -> Int {
            let recording = RecordingGitRunner(forwardingTo: .hermetic())
            let probe = shared ? RepositoryProbe(git: recording) : nil
            #expect(BranchResolver(git: recording, probe: probe).branch(for: repo) == "main")
            #expect(RemoteResolver(git: recording, probe: probe).remote(for: repo) == .remote("git@example.com:app.git"))
            #expect(DefaultBranchResolver(git: recording, probe: probe).defaultBranch(for: repo) == "main")
            return probes(recording)
        }
        #expect(spawns(shared: false) == 3)
        #expect(spawns(shared: true) == 1)
    }

    /// A folder that is not a repository costs one spawn for all three, and again once the negative
    /// window is over — not three each time.
    @Test func aFolderThatIsNotARepositoryIsProbedOnceForAllThree() throws {
        let folder = try GitFixture.folder("probe-none-"), clock = TestClock()
        let recording = RecordingGitRunner(forwardingTo: .hermetic()), now: @Sendable () -> Date = { clock.now }
        let probe = RepositoryProbe(git: recording, now: now)
        let branches = BranchResolver(git: recording, now: now, probe: probe), remotes = RemoteResolver(git: recording, now: now, probe: probe)
        let defaults = DefaultBranchResolver(git: recording, now: now, probe: probe)
        func ask() {
            #expect(branches.branch(for: folder) == nil)
            #expect(remotes.remote(for: folder) == .notARepository)
            #expect(defaults.defaultBranch(for: folder) == nil)
        }
        ask(); ask()
        #expect(probes(recording) == 1)
        clock.advance(by: 31)
        ask()
        #expect(probes(recording) == 2)
        try git.run(["init", "-q", "-b", "main"], in: folder)
        clock.advance(by: 31)
        #expect(branches.branch(for: folder) == "main", "no commit yet, but a repository now, and not the cached 'not one'")
        #expect(remotes.remote(for: folder) == .remote(nil))
        #expect(probes(recording) == 3)
    }

    /// The paths do not change while the repository stands, so a checkout that moves HEAD does not
    /// cost another spawn; one whose repository went away is probed again, and is no longer one.
    @Test func anAnswerLastsAsLongAsTheRepositoryDoes() throws {
        let repo = try GitFixture.makeRepo(prefix: "probe-", git: git)
        let recording = RecordingGitRunner(forwardingTo: .hermetic()), probe = RepositoryProbe(git: recording)
        _ = try probe.locations(of: repo)
        try git.run(["checkout", "-q", "-b", "feat/x"], in: repo)
        _ = try probe.locations(of: repo)
        #expect(probes(recording) == 1)
        try FileManager.default.removeItem(atPath: repo + "/.git")
        #expect(try probe.locations(of: repo) == nil)
        #expect(probes(recording) == 2)
    }

    /// A timeout is thrown, not kept as an answer, and git is left alone for the backoff.
    @Test func aTimeoutIsNotKeptAndIsNotAskedAgainAtOnce() throws {
        let repo = try GitFixture.makeRepo(prefix: "probe-", git: git), clock = TestClock()
        let flaky = FlakyGitRunner()
        let probe = RepositoryProbe(git: flaky, now: { clock.now })
        flaky.failing = true
        #expect(throws: GitError.self) { try probe.locations(of: repo) }
        flaky.failing = false
        #expect(throws: GitError.self) { try probe.locations(of: repo) }
        #expect(flaky.calls == 1, "within the backoff git is not asked")
        clock.advance(by: TimedOut.backoff)
        #expect(try probe.locations(of: repo)?.head == real(repo) + "/.git/HEAD")
    }

    /// What `retain` drops is looked up again.
    @Test func retainForgetsTheDirectoriesNoLongerLive() throws {
        let repo = try GitFixture.makeRepo(prefix: "probe-", git: git)
        let recording = RecordingGitRunner(forwardingTo: .hermetic()), probe = RepositoryProbe(git: recording)
        _ = try probe.locations(of: repo)
        probe.retain(only: [repo])
        _ = try probe.locations(of: repo)
        #expect(probes(recording) == 1)
        probe.retain(only: [])
        _ = try probe.locations(of: repo)
        #expect(probes(recording) == 2)
    }
}
