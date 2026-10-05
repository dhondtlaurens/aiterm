import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// What the checkout monitor's pass costs in git processes, for a workspace of two projects with
/// three tasks each and a tab in every checkout, as a counting runner sees it. The numbers are the
/// point of these tests: a change that makes a pass spawn more has to say so here.
///
/// Before the shared probe, the batched ref queries and the cached untracked counts, the same
/// workspace cost 55 spawns on the first pass and 12 on a pass after the diffs' ttl expired.
struct GitSpawnCountTests {
    private let git = GitRunner.hermetic()

    private struct Workspace {
        var projects: [Project], tasks: [TaskItem], cwds: [String]
    }

    private func task(_ project: Project, _ path: String) -> TaskItem {
        TaskItem(id: UUID(), projectId: project.id, title: "t", branch: "b", worktreePath: path, baseBranch: "main",
                 jira: nil, agent: .claude, model: "m", reasoning: nil, firstPrompt: nil, appendTicket: false,
                 createdAt: Date(), windowId: nil)
    }

    /// Two repositories, each with three task worktrees holding one untracked file, and a folder
    /// that is not a repository, where one more tab sits.
    private func makeWorkspace() throws -> Workspace {
        var workspace = Workspace(projects: [], tasks: [], cwds: [try GitFixture.folder("not-a-repo-")])
        for name in ["one", "two"] {
            let repo = try GitFixture.makeRepo(prefix: "spawns-\(name)-", git: git)
            let project = Project(id: UUID(), name: name, path: repo, provider: .gitlab, remoteUrl: nil, addedAt: Date(), collapsed: false)
            try git.run(["remote", "add", "origin", "git@gitlab.example.com:group/\(name).git"], in: repo)
            workspace.projects.append(project)
            workspace.cwds.append(repo)
            for slug in ["a", "b", "c"] {
                let path = repo + "/.worktrees/" + slug
                try git.run(["worktree", "add", "-q", "-b", "feat/" + slug, path], in: repo)
                try "new\nfile\n".write(toFile: path + "/untracked.txt", atomically: true, encoding: .utf8)
                workspace.tasks.append(task(project, path))
                workspace.cwds.append(path)
            }
        }
        return workspace
    }

    /// The resolvers a monitor builds, over `runner`, and a clock to move.
    private struct Passes {
        let clock = TestClock()
        let workspace: Workspace
        let branches: BranchResolver, remotes: RemoteResolver, diffs: DiffStatResolver, defaults: DefaultBranchResolver

        init(_ workspace: Workspace, runner: any GitRunning) {
            self.workspace = workspace
            let clock = self.clock, now: @Sendable () -> Date = { clock.now }
            let probe = RepositoryProbe(git: runner, now: now)
            branches = BranchResolver(git: runner, now: now, probe: probe)
            remotes = RemoteResolver(git: runner, now: now, probe: probe)
            diffs = DiffStatResolver(git: runner, now: now, ttl: 5)
            defaults = DefaultBranchResolver(git: runner, now: now, probe: probe)
        }

        func pass() -> WorkspaceScan {
            WorkspaceScan.run(cwds: workspace.cwds, projects: workspace.projects, tasks: workspace.tasks,
                              branches: branches, remotes: remotes, diffs: diffs, defaultBranches: defaults)
        }
    }

    private func commands(_ recording: RecordingGitRunner, since mark: Int) -> [String] {
        recording.calls.dropFirst(mark).map { $0.args.prefix(2).joined(separator: " ") }
    }

    /// 9 `rev-parse` to find the files of the 8 checkouts and the folder that is not one, 4 to read the
    /// remotes, 2 for the default branches, and 5 a task: where its base is (`rev-parse`, 2 `merge-base`),
    /// then the diff and the untracked listing.
    @Test func theFirstPassSpawnsWhatEachDirectoryNeedsOnce() throws {
        let recording = RecordingGitRunner(forwardingTo: .hermetic())
        let passes = Passes(try makeWorkspace(), runner: recording)
        let scan = passes.pass()
        #expect(scan.diffByTask.count == 6 && scan.diffByTask.values.allSatisfy { $0 == DiffStat(added: 2, removed: 0) })
        #expect(scan.remotes.count == 2 && scan.defaultBranch.count == 2)
        let spawned = commands(recording, since: 0)
        #expect(spawned.count == 45, "\(spawned)")
        #expect(spawned.filter { $0 == "rev-parse --path-format=absolute" }.count == 9)
        #expect(spawned.filter { $0 == "for-each-ref --format=%(refname) %(symref)" }.count == 2)
    }

    /// The monitor ticks every two seconds and the diffs last five: most passes spawn nothing, and
    /// one in three spawns the two commands a diff needs per task — and reads no untracked file that
    /// did not change.
    @Test func aSteadyStatePassSpawnsNothingUntilADiffExpires() throws {
        let recording = RecordingGitRunner(forwardingTo: .hermetic())
        let passes = Passes(try makeWorkspace(), runner: recording)
        _ = passes.pass()
        var mark = recording.calls.count
        passes.clock.advance(by: 2)
        _ = passes.pass()
        #expect(commands(recording, since: mark).isEmpty)
        mark = recording.calls.count
        passes.clock.advance(by: 4)
        _ = passes.pass()
        let spawned = commands(recording, since: mark)
        #expect(spawned.count == 12, "\(spawned)")
        #expect(spawned.filter { $0 == "diff --numstat" }.count == 6 && spawned.filter { $0 == "ls-files --others" }.count == 6)
    }

    /// A folder that is not a repository, in every project's place and again every thirty seconds,
    /// cost three `rev-parse` each time, one per resolver.
    @Test func aProjectThatIsNotARepositoryCostsOneSpawnPerNegativeWindow() throws {
        let folder = try GitFixture.folder("not-a-repo-")
        let project = Project(id: UUID(), name: "gone", path: folder, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
        let recording = RecordingGitRunner(forwardingTo: .hermetic())
        let passes = Passes(Workspace(projects: [project], tasks: [], cwds: []), runner: recording)
        _ = passes.pass(); _ = passes.pass()
        #expect(recording.calls.count == 1)
        passes.clock.advance(by: 31)
        _ = passes.pass()
        #expect(recording.calls.count == 2)
    }

    /// The branch list, the default branch and `isMerged` each ask git once where they asked up to
    /// five times, and the answers are the ones they gave.
    @Test func refQueriesAreSingleCalls() throws {
        let repo = try GitFixture.makeRepo(prefix: "refs-", git: git)
        try git.run(["branch", "feat/x"], in: repo)
        let recording = RecordingGitRunner(forwardingTo: .hermetic())
        /// What `body` answers, and how many commands it took.
        func counted<Answer>(_ body: () throws -> Answer) rethrows -> (answer: Answer, spawns: Int) {
            let mark = recording.calls.count
            let answer = try body()
            return (answer, recording.calls.count - mark)
        }
        let defaultBranch = try counted { try Worktrees.detectDefaultBranch(repo: repo, git: recording) }
        #expect(defaultBranch.answer == "main" && defaultBranch.spawns == 1)
        let branches = counted { Worktrees.branches(repo: repo, git: recording) }
        #expect(branches.answer == ["main", "feat/x"] && branches.spawns == 2)
        let merged = counted { Worktrees.isMerged(branch: "feat/x", into: "main", repo: repo, git: recording) }
        #expect(merged.answer && merged.spawns == 1)
        let unknown = counted { Worktrees.isMerged(branch: "feat/x", into: "gone", repo: repo, git: recording) }
        #expect(!unknown.answer && unknown.spawns == 2, "the local and the origin ref, neither of which exists")
    }

    /// A project on a dead mount: every git there waits out its whole deadline, ten seconds. Before
    /// the shared probe and the backoff, every pass paid it nine times over — each resolver for the
    /// project, its three tabs, its three diffs — so a pass could take a minute and a half, forever.
    /// Now the first pass pays it for each directory once (seven times) and the passes after, until
    /// the backoff is over, not at all.
    @Test func aHungMountIsPaidForOnceAndThenLeftAlone() throws {
        let workspace = try makeWorkspace()
        let hung = HungMount(under: workspace.projects[0].path)
        let passes = Passes(workspace, runner: hung)
        _ = passes.pass()
        #expect(hung.timeouts == 7, "the project's probe, its three tabs' and its three diffs'")
        let first = passes.pass()
        passes.clock.advance(by: 2)
        _ = passes.pass()
        #expect(hung.timeouts == 7, "the next passes within the backoff do not wait for it again")
        #expect(first.diffByTask.count == 3, "the other project is unaffected")
        passes.clock.advance(by: TimedOut.backoff)
        _ = passes.pass()
        #expect(hung.timeouts == 14, "once the backoff is over it is asked again, once each")
    }
}

/// A git for which everything under one folder times out, as a dead network mount does, and
/// everything else runs for real. It counts the commands that timed out.
private final class HungMount: GitRunning {
    private let folder: String
    private let inner: any GitRunning = GitRunner.hermetic()
    private let count = Mutex(0)
    var timeouts: Int { count.withLock { $0 } }
    init(under folder: String) { self.folder = folder }

    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        guard dir == folder || dir.hasPrefix(folder + "/") else { return try inner.run(args, in: dir, timeout: timeout, environment: environment) }
        count.withLock { $0 += 1 }
        throw GitError(args: args, code: 15, stderr: "git \(args.first ?? "") timed out after \(timeout) s")
    }
}
