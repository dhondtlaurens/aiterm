import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The one `rev-parse` that names the files the two resolvers watch.
@Suite(.blocking) struct RepositoryProbeTests {
    private let git = GitRunner.hermetic()

    /// The path git reports, which has no symlink in it: `/private/var/…` for the temporary directory.
    private func real(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func probes(_ runner: RecordingGitRunner) -> Int {
        runner.calls.filter { $0.args.contains("--git-path") }.count
    }

    @Test func namesTheFilesOfAnOrdinaryCheckout() throws {
        let repo = try GitFixture.makeRepo(prefix: "probe-", git: git)
        let found = try #require(try RepositoryProbe(git: git).locations(of: repo)), root = real(repo)
        #expect(found == RepositoryProbe.Locations(head: root + "/.git/HEAD",
                                                   config: root + "/.git/config"))
    }

    /// From a linked worktree `HEAD` is its own, and the config the repository's.
    @Test func namesTheFilesOfALinkedWorktree() throws {
        let repo = try GitFixture.makeRepo(prefix: "probe-", git: git)
        let worktree = repo + "/.worktrees/feat"
        try git.run(["worktree", "add", "-q", "-b", "feat/x", worktree], in: repo)
        let found = try #require(try RepositoryProbe(git: git).locations(of: worktree)), root = real(repo)
        #expect(found.head == root + "/.git/worktrees/feat/HEAD")
        #expect(found.config == root + "/.git/config")
    }

    /// Both resolvers share one `rev-parse` for a project without changing their answers.
    @Test func theTwoResolversShareOneSpawn() throws {
        let repo = try GitFixture.makeRepo(prefix: "probe-", git: git)
        try git.run(["remote", "add", "origin", "git@example.com:app.git"], in: repo)
        func spawns(shared: Bool) -> Int {
            let recording = RecordingGitRunner(forwardingTo: .hermetic())
            let probe = shared ? RepositoryProbe(git: recording) : nil
            #expect(BranchResolver(git: recording, probe: probe).branch(for: repo) == "main")
            #expect(RemoteResolver(git: recording, probe: probe).remote(for: repo) == .remote("git@example.com:app.git"))
            return probes(recording)
        }
        #expect(spawns(shared: false) == 2)
        #expect(spawns(shared: true) == 1)
    }

    /// A folder that is not a repository costs one spawn for both, and again once the negative
    /// window is over — not two each time.
    @Test func aFolderThatIsNotARepositoryIsProbedOnceForBoth() throws {
        let folder = try GitFixture.folder("probe-none-"), clock = TestClock()
        let recording = RecordingGitRunner(forwardingTo: .hermetic()), now: @Sendable () -> Date = { clock.now }
        let probe = RepositoryProbe(git: recording, now: now)
        let branches = BranchResolver(git: recording, now: now, probe: probe), remotes = RemoteResolver(git: recording, now: now, probe: probe)
        func ask() {
            #expect(branches.branch(for: folder) == nil)
            #expect(remotes.remote(for: folder) == .notARepository)
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

    /// A timeout is thrown, not kept as an answer, and the next call asks again.
    @Test func aTimeoutIsNotKeptAndTheNextCallAsksAgain() throws {
        let repo = try GitFixture.makeRepo(prefix: "probe-", git: git), clock = TestClock()
        let flaky = FlakyGitRunner()
        let probe = RepositoryProbe(git: flaky, now: { clock.now })
        flaky.failing = true
        #expect(throws: GitError.self) { try probe.locations(of: repo) }
        flaky.failing = false
        #expect(try probe.locations(of: repo)?.head == real(repo) + "/.git/HEAD")
        #expect(flaky.calls == 2)
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
