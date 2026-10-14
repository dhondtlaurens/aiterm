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

    private func plan(branch: String = "feat/x", drops: [String] = []) -> FixProposal {
        FixProposal(headline: "h", why: "w", steps: ["s"], moves: [branch], drops: drops, verify: nil)
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

    // MARK: the branch that lands

    /// Landing moves refs only, so the branch's own tip is read, wherever HEAD is.
    @Test func markersCommittedOnTheBranchAreRefusedWhereverHeadIs() throws {
        let start = before
        try resolve(with: "<<<<<<< HEAD\ntopic=theirs\n=======\ntopic=mine\n>>>>>>> mine\n")
        try git.run(["checkout", "-q", "main"], in: clone.path)
        #expect(throws: FixRefusal.conflictMarkers(["config.ts"])) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    @Test func aCleanBranchPassesWithHeadElsewhere() throws {
        let start = before
        try resolve(with: "topic=both\n")
        try git.run(["checkout", "-q", "main"], in: clone.path)
        try FixGuard.check(clone, proposal: plan(), before: start)
    }

    @Test func aPathWithColonsIsNamedWhole() throws {
        let start = before
        try resolve(with: "topic=both\n")
        try "<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> z\n".write(toFile: clone.path + "/a:b.ts", atomically: true, encoding: .utf8)
        try git.run(["add", "a:b.ts"], in: clone.path)
        try git.run(["commit", "-q", "-m", "more"], in: clone.path)
        #expect(throws: FixRefusal.conflictMarkers(["a:b.ts"])) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    @Test func otherStoppedOperationsAreRefused() throws {
        try git.run(["rebase", "--abort"], in: clone.path)
        for state in ["REVERT_HEAD", "BISECT_LOG", "sequencer"] {
            let path = clone.path + "/.git/" + state
            try Data().write(to: URL(fileURLWithPath: path))
            #expect(throws: FixRefusal.operationInProgress) { try FixGuard.check(clone, proposal: plan(), before: before) }
            try FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: markers that are not the agent's

    /// A line origin already had — an RST underline — is `=======` to `diff --check`, but not the fix's doing.
    @Test func aMarkerLookalikeFromOriginIsNotTheFixes() throws {
        let (world, clone) = try second { world in
            try world.commit("docs", file: "doc.rst", contents: "Title\n=======\n", in: world.other)
            try self.git.run(["push", "-q", "origin", "feat/x"], in: world.other)
            try self.git.run(["fetch", "-q", "origin"], in: world.repo)
        }
        defer { clone.remove(); world.removeAll() }
        let start = (try? clone.branchTips()) ?? [:]
        try "topic=both\n".write(toFile: clone.path + "/config.ts", atomically: true, encoding: .utf8)
        try git.run(["add", "config.ts"], in: clone.path)
        try git.run(["-c", "core.editor=true", "rebase", "--continue"], in: clone.path)
        try FixGuard.check(clone, proposal: plan(), before: start)
    }

    // MARK: lost commits

    /// A commit of origin's with the lost commit's identity is not a twin: origin has it already.
    @Test func anOriginCommitWithTheSameIdentityDoesNotVouch() throws {
        let (world, clone) = try second { world in
            let date = try self.git.run(["log", "-1", "--format=%at", "feat/x"], in: world.repo) + " +0000"
            try "x\n".write(toFile: world.other + "/other.txt", atomically: true, encoding: .utf8)
            try self.git.run(["add", "other.txt"], in: world.other)
            try self.git.run(["commit", "-q", "-m", "mine"], in: world.other, timeout: GitRunner.localTimeout,
                             environment: ["GIT_AUTHOR_DATE": date])
            try self.git.run(["push", "-q", "origin", "feat/x"], in: world.other)
            try self.git.run(["fetch", "-q", "origin"], in: world.repo)
        }
        defer { clone.remove(); world.removeAll() }
        let start = (try? clone.branchTips()) ?? [:]
        try git.run(["rebase", "--abort"], in: clone.path)
        try git.run(["reset", "-q", "--hard", "origin/feat/x"], in: clone.path)
        let mine = try world.sha("feat/x", in: world.repo)
        #expect(throws: FixRefusal.droppedCommit("feat/x", sha: mine)) { try FixGuard.check(clone, proposal: plan(), before: start) }
    }

    @Test func tooManyLocalOnlyCommitsAreRefused() throws {
        let start = before
        try resolve(with: "topic=both\n")
        #expect(throws: FixRefusal.tooManyCommits("feat/x", count: 1)) { try FixGuard.check(clone, proposal: plan(), before: start, limit: 0) }
        try FixGuard.check(clone, proposal: plan(), before: start, limit: 1)
    }

    /// With no origin the history is not the count: only what the fix left out of the new tip is.
    @Test func aLocalOnlyBranchWithALongHistoryPassesACleanFix() throws {
        let (world, clone) = try localOnly(commits: 1, over: 5)
        defer { clone.remove(); world.removeAll() }
        let start = (try? clone.branchTips()) ?? [:]
        try git.run(["commit", "-q", "--amend", "-m", "reworded"], in: clone.path)
        try FixGuard.check(clone, proposal: plan(branch: "local/y"), before: start, limit: 3)
    }

    /// Two identical “wip” commits squashed into one: one twin, two commits to vouch for.
    @Test func oneTwinVouchesForOneCommit() throws {
        let (world, clone) = try localOnly(commits: 2, over: 1)
        defer { clone.remove(); world.removeAll() }
        let start = (try? clone.branchTips()) ?? [:]
        let wips = try git.run(["rev-list", "--reverse", "main..local/y"], in: clone.path).split(separator: "\n").map(String.init)
        try git.run(["reset", "-q", "--soft", "main"], in: clone.path)
        try git.run(["commit", "-q", "-m", "wip"], in: clone.path, timeout: GitRunner.localTimeout, environment: Self.wipDate)
        #expect(throws: FixRefusal.droppedCommit("local/y", sha: wips[1])) {
            try FixGuard.check(clone, proposal: plan(branch: "local/y"), before: start)
        }
    }

    // MARK: fixtures

    private static let wipDate = ["GIT_AUTHOR_DATE": "1700000000 +0000"]

    /// Another world and clone, after `prepare` has changed what origin holds.
    private func second(_ prepare: (ConflictWorld) throws -> Void) throws -> (ConflictWorld, FixClone) {
        let world = try ConflictWorld(git: .hermetic())
        try prepare(world)
        let clone = try FixClone.make(for: FixRequest(title: "t", reason: nil, detail: nil, projectPath: world.repo, branch: "feat/x",
                                                       recreateRebase: true, retry: .createReview), git: .hermetic(), root: world.root)
        return (world, clone)
    }

    /// A world whose `local/y` has `commits` commits named “wip” on top of `base` more commits of `main`,
    /// and no origin; its clone is on it.
    private func localOnly(commits: Int, over base: Int) throws -> (ConflictWorld, FixClone) {
        let world = try ConflictWorld(git: .hermetic())
        for i in 1...base { try world.commit("main \(i)", file: "m.txt", contents: "\(i)\n", in: world.repo) }
        try git.run(["checkout", "-q", "-b", "local/y"], in: world.repo)
        for i in 1...commits {
            try "\(i)\n".write(toFile: world.repo + "/w\(i).txt", atomically: true, encoding: .utf8)
            try git.run(["add", "."], in: world.repo)
            try git.run(["commit", "-q", "-m", "wip"], in: world.repo, timeout: GitRunner.localTimeout, environment: Self.wipDate)
        }
        try git.run(["checkout", "-q", "main"], in: world.repo)
        let clone = try FixClone.make(for: FixRequest(title: "t", reason: nil, detail: nil, projectPath: world.repo, branch: "local/y",
                                                       recreateRebase: false, retry: .createReview), git: .hermetic(), root: world.root)
        return (world, clone)
    }
}

