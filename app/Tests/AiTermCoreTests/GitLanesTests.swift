import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct GitLanesTests {
    let git = GitRunner.hermetic()

    /// The rendezvous: a job on one repository's lane waits for a job on another's to start. On one
    /// queue for every repository, as before, the second could never start while the first waited, and
    /// the first gave up at its deadline.
    @Test func workOnOneRepositoryNeverWaitsForAnother() async throws {
        let lanes = GitLanes()
        let a = try GitFixture.makeRepo(prefix: "lane-a-", git: git), b = try GitFixture.makeRepo(prefix: "lane-b-", git: git)
        let started = DispatchSemaphore(value: 0)
        let met = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lanes.lane(for: a).async { continuation.resume(returning: started.wait(timeout: .now() + 10) == .success) }
            lanes.lane(for: b).async { started.signal() }
        }
        #expect(met, "the other repository's job ran while this one's waited")
    }

    /// A repository's own folder, a folder inside it and each of its worktrees are one repository, and
    /// one lane: two changes to it never interleave.
    @Test func aRepositoryItsFoldersAndItsWorktreesShareOneLane() throws {
        let lanes = GitLanes()
        let repo = try GitFixture.makeRepo(prefix: "lane-", git: git)
        let worktree = repo + "/.worktrees/w"
        try git.run(["worktree", "add", "-q", "-b", "feat/w", worktree], in: repo)
        try FileManager.default.createDirectory(atPath: repo + "/sub", withIntermediateDirectories: true)
        let lane = lanes.lane(for: repo)
        #expect(lanes.lane(for: worktree) === lane)
        #expect(lanes.lane(for: repo + "/sub") === lane)
        #expect(lanes.lane(for: repo + "/") === lane)
        #expect(GitLanes.repository(of: worktree) == CanonicalPath.of(repo + "/.git"))
    }
}
