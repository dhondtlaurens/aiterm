import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct WorkspaceScanTests {
    private func makeRepo(remote: String) throws -> String {
        let repo = try GitFixture.makeRepo(prefix: "ws-")
        try GitRunner.hermetic().run(["remote", "add", "origin", remote], in: repo)
        return repo
    }

    private func scan(_ project: Project, git: any GitRunning, resolvers: Resolvers) -> WorkspaceScan {
        WorkspaceScan.run(cwds: [], projects: [project], tasks: [], branches: resolvers.branches, remotes: resolvers.remotes,
                          diffs: DiffStatResolver(git: git), defaultBranches: resolvers.defaultBranches)
    }

    private struct Resolvers {
        let branches: BranchResolver, remotes: RemoteResolver, defaultBranches: DefaultBranchResolver
        init(git: any GitRunning, now: @escaping @Sendable () -> Date = Date.init) {
            let probe = RepositoryProbe(git: git, now: now)
            branches = BranchResolver(git: git, now: now, probe: probe); remotes = RemoteResolver(git: git, now: now, probe: probe)
            defaultBranches = DefaultBranchResolver(git: git, now: now, probe: probe)
        }
    }

    /// A pass whose git calls time out has found nothing out about the project, which is not the
    /// same as finding it has no remote: `AppState.adoptRemotes` clears and saves the stored remote of
    /// every project the scan reports, so the project is left out of it.
    @Test func aProjectGitCouldNotBeAskedAboutReportsNoRemote() throws {
        let url = "git@gitlab.example.com:group/app.git"
        let repo = try makeRepo(remote: url)
        let project = Project(id: UUID(), name: "app", path: repo, provider: .gitlab, remoteUrl: url, addedAt: Date(), collapsed: false)
        let flaky = FlakyGitRunner(), clock = TestClock(), resolvers = Resolvers(git: flaky, now: { clock.now })
        flaky.failing = true
        let failed = scan(project, git: flaky, resolvers: resolvers)
        #expect(failed.remotes.isEmpty)
        #expect(failed.defaultBranch.isEmpty)
        flaky.failing = false
        clock.advance(by: TimedOut.backoff)
        let recovered = scan(project, git: flaky, resolvers: resolvers)
        #expect(recovered.remotes[project.id]?.url == url)
        #expect(recovered.defaultBranch[project.id] == "main")
    }

    /// And once a remote is known, a later failure leaves it as it was.
    @Test func aKnownRemoteSurvivesAFailedReRead() throws {
        let url = "git@gitlab.example.com:group/app.git"
        let repo = try makeRepo(remote: url)
        let project = Project(id: UUID(), name: "app", path: repo, provider: .gitlab, remoteUrl: url, addedAt: Date(), collapsed: false)
        let flaky = FlakyGitRunner(), clock = TestClock(), resolvers = Resolvers(git: flaky, now: { clock.now })
        #expect(scan(project, git: flaky, resolvers: resolvers).remotes[project.id]?.url == url)
        try GitRunner.hermetic().run(["remote", "set-url", "origin", "git@gitlab.example.com:group/moved.git"], in: repo)
        flaky.failing = true
        #expect(scan(project, git: flaky, resolvers: resolvers).remotes[project.id]?.url == url)
        flaky.failing = false
        clock.advance(by: TimedOut.backoff)
        #expect(scan(project, git: flaky, resolvers: resolvers).remotes[project.id]?.url == "git@gitlab.example.com:group/moved.git")
    }

    /// A pass keeps what the resolvers learned only for the directories it names: a tab that has left
    /// a directory — a worktree removed, a `cd` elsewhere — no longer holds it in memory, and the
    /// directory is looked at afresh if a tab comes back. A project's own is kept throughout.
    @Test func aPassForgetsADirectoryNoTabIsInAnyMore() throws {
        let url = "git@gitlab.example.com:group/app.git"
        let repo = try makeRepo(remote: url), elsewhere = try GitFixture.makeRepo(prefix: "ws-tab-")
        let project = Project(id: UUID(), name: "app", path: repo, provider: .gitlab, remoteUrl: url, addedAt: Date(), collapsed: false)
        let recording = RecordingGitRunner(forwardingTo: .hermetic()), resolvers = Resolvers(git: recording)
        let diffs = DiffStatResolver(git: recording)
        func pass(_ cwds: [String]) {
            _ = WorkspaceScan.run(cwds: cwds, projects: [project], tasks: [], branches: resolvers.branches, remotes: resolvers.remotes,
                                  diffs: diffs, defaultBranches: resolvers.defaultBranches)
        }
        pass([elsewhere])
        let known = recording.calls.count
        pass([elsewhere])
        #expect(recording.calls.count == known, "everything is cached")
        pass([])
        pass([elsewhere])
        #expect(recording.calls.count == known + 1, "the tab's directory was forgotten, and the project's was not")
    }
}
