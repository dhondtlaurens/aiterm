import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

struct WorkspaceScanTests {
    private func makeRepo(remote: String) throws -> String {
        let git = GitRunner.hermetic()
        let dir = NSTemporaryDirectory() + "ws-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // git reports /private/var..., Foundation reports /var...; resolve once so the two agree.
        let repo = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        try git.run(["init", "--initial-branch=main", "-q", repo], in: "/")
        try git.run(["-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "--allow-empty", "-q", "-m", "init"], in: repo)
        try git.run(["remote", "add", "origin", remote], in: repo)
        return repo
    }

    private func scan(_ project: Project, git: GitRunner, resolvers: Resolvers) -> WorkspaceScan {
        WorkspaceScan.run(cwds: [], projects: [project], tasks: [], branches: resolvers.branches, remotes: resolvers.remotes,
                          diffs: DiffStatResolver(git: git), defaultBranches: resolvers.defaultBranches)
    }

    private struct Resolvers {
        let branches: BranchResolver, remotes: RemoteResolver, defaultBranches: DefaultBranchResolver
        init(git: GitRunner) {
            branches = BranchResolver(git: git); remotes = RemoteResolver(git: git); defaultBranches = DefaultBranchResolver(git: git)
        }
    }

    /// A pass whose git calls time out has found nothing out about the project, which is not the
    /// same as finding it has no remote: `applyRemotes` clears and saves the stored remote of
    /// every project the scan reports, so the project is left out of it.
    @Test func aProjectGitCouldNotBeAskedAboutReportsNoRemote() throws {
        let url = "git@gitlab.example.com:group/app.git"
        let repo = try makeRepo(remote: url)
        let project = Project(id: UUID(), name: "app", path: repo, provider: .gitlab, remoteUrl: url, addedAt: Date(), collapsed: false)
        let flaky = FlakyGitRunner(), resolvers = Resolvers(git: flaky)
        flaky.failing = true
        let failed = scan(project, git: flaky, resolvers: resolvers)
        #expect(failed.remotes.isEmpty)
        #expect(failed.defaultBranch.isEmpty)
        flaky.failing = false
        let recovered = scan(project, git: flaky, resolvers: resolvers)
        #expect(recovered.remotes[project.id]?.url == url)
        #expect(recovered.defaultBranch[project.id] == "main")
    }

    /// And once a remote is known, a later failure leaves it as it was.
    @Test func aKnownRemoteSurvivesAFailedReRead() throws {
        let url = "git@gitlab.example.com:group/app.git"
        let repo = try makeRepo(remote: url)
        let project = Project(id: UUID(), name: "app", path: repo, provider: .gitlab, remoteUrl: url, addedAt: Date(), collapsed: false)
        let flaky = FlakyGitRunner(), resolvers = Resolvers(git: flaky)
        #expect(scan(project, git: flaky, resolvers: resolvers).remotes[project.id]?.url == url)
        try GitRunner.hermetic().run(["remote", "set-url", "origin", "git@gitlab.example.com:group/moved.git"], in: repo)
        flaky.failing = true
        #expect(scan(project, git: flaky, resolvers: resolvers).remotes[project.id]?.url == url)
        flaky.failing = false
        #expect(scan(project, git: flaky, resolvers: resolvers).remotes[project.id]?.url == "git@gitlab.example.com:group/moved.git")
    }
}
