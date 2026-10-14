import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) final class FixGuardTests {
    let git = GitRunner.hermetic()
    let world: ConflictWorld
    let clone: FixClone

    init() throws {
        world = try ConflictWorld(git: .hermetic())
        clone = try FixClone.make(for: FixRequest(title: "t", reason: nil, detail: nil, projectPath: world.repo, branch: "feat/x",
                                                   recreateRebase: true, retry: .createReview), git: .hermetic(), root: world.root)
        // A second branch in the clone, so “moved another branch” has one to move.
        try git.run(["branch", "-f", "main", "origin/feat/x"], in: clone.path)
    }
    deinit { clone.remove(); world.removeAll() }

    /// The tips as the pipeline reads them before Apply.
    private var before: [String: String] { (try? clone.branchTips()) ?? [:] }

    private func plan(drops: [String] = []) -> FixProposal {
        FixProposal(headline: "h", why: "w", steps: ["s"], moves: ["feat/x"], drops: drops, verify: nil)
    }
    private func resolve(with contents: String) throws {
        try contents.write(toFile: clone.path + "/config.ts", atomically: true, encoding: .utf8)
        try git.run(["add", "config.ts"], in: clone.path)
        try git.run(["-c", "core.editor=true", "rebase", "--continue"], in: clone.path)
    }

    @Test func aRebaseLeftStoppedIsRefused() {
        #expect(throws: FixRefusal.operationInProgress) { try FixGuard.check(clone, proposal: plan(), before: before) }
    }

    @Test func leftoverMarkersAreRefused() throws {
        let start = before
        try resolve(with: "<<<<<<< HEAD\ntopic=theirs\n=======\ntopic=mine\n>>>>>>> mine\n")
        #expect(throws: FixRefusal.conflictMarkers(["config.ts"])) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    @Test func aCleanResolutionKeepingTheCommitPasses() throws {
        let start = before
        try resolve(with: "topic=both\n")
        try FixGuard.check(clone, proposal: plan(), before: start)
    }

    /// Spec §7.2: the local commit replaced by origin's without saying so.
    @Test func anUndeclaredDropIsRefused() throws {
        let start = before
        try git.run(["rebase", "--abort"], in: clone.path)
        try git.run(["reset", "-q", "--hard", "origin/feat/x"], in: clone.path)
        let mine = try world.sha("feat/x", in: world.repo)
        #expect(throws: FixRefusal.droppedCommit("feat/x", sha: mine)) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    @Test func aDeclaredDropPasses() throws {
        let start = before
        try git.run(["rebase", "--abort"], in: clone.path)
        try git.run(["reset", "-q", "--hard", "origin/feat/x"], in: clone.path)
        try FixGuard.check(clone, proposal: plan(drops: [try world.sha("feat/x", in: world.repo)]), before: start)
    }

    /// By content first: a reworded commit has a new sha and subject but the same patch.
    @Test func aCommitKeptByItsPatchPasses() throws {
        let start = before
        try git.run(["rebase", "--abort"], in: clone.path)
        try git.run(["commit", "-q", "--amend", "-m", "reworded"], in: clone.path)
        try FixGuard.check(clone, proposal: plan(), before: start)
    }

    @Test func movingAnotherBranchIsRefused() throws {
        let start = before
        try resolve(with: "topic=both\n")
        try git.run(["branch", "-f", "main", "HEAD"], in: clone.path)
        #expect(throws: FixRefusal.movedOtherBranch("main")) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    @Test func uncommittedChangesAreRefused() throws {
        let start = before
        try resolve(with: "topic=both\n")
        try "extra\n".write(toFile: clone.path + "/config.ts", atomically: true, encoding: .utf8)
        #expect(throws: FixRefusal.uncommittedChanges) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }
}
