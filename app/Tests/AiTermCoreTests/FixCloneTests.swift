import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// The clone a fix works in: it shares the project's objects, has no remote and no hooks, starts on
/// the project's tip of the branch, and goes on every path.
@Suite(.blocking) final class FixCloneTests {
    let git = GitRunner.hermetic()
    let world: ConflictWorld
    init() throws { world = try ConflictWorld(git: .hermetic()) }
    deinit { world.removeAll() }

    private func request(rebase: Bool = true) -> FixRequest {
        FixRequest(title: "t", reason: nil, detail: nil, projectPath: world.repo, branch: "feat/x",
                   recreateRebase: rebase, retry: .createReview)
    }

    /// The fixture itself: a fixture that silently does not diverge would make every test above it pass for nothing.
    @Test func theWorldReallyDiverges() throws {
        #expect(try git.run(["rev-list", "--left-right", "--count", "feat/x...origin/feat/x"], in: world.repo) == "1\t1")
    }

    @Test func sharesObjectsHasNoRemoteAndNoHooks() throws {
        let clone = try FixClone.make(for: request(rebase: false), git: git, root: world.root)
        defer { clone.remove() }
        #expect(FileManager.default.fileExists(atPath: clone.path + "/.git/objects/info/alternates"))
        #expect(try git.run(["remote"], in: clone.path).isEmpty)
        #expect(try git.run(["config", "core.hooksPath"], in: clone.path) == "/dev/null")
        #expect(try clone.tip("feat/x") == world.sha("feat/x", in: world.repo))
        #expect(clone.startTip == (try world.sha("feat/x", in: world.repo)))
        #expect(try git.run(["rev-parse", "origin/feat/x"], in: clone.path) == world.sha("origin/feat/x", in: world.repo))
    }

    @Test func recreatesTheStoppedRebase() throws {
        let clone = try FixClone.make(for: request(), git: git, root: world.root)
        defer { clone.remove() }
        #expect(try git.run(["status", "--porcelain"], in: clone.path).contains("UU config.ts"))
    }

    @Test func localOnlyIsTheBranchsCommitsOriginLacks() throws {
        let clone = try FixClone.make(for: request(rebase: false), git: git, root: world.root)
        defer { clone.remove() }
        #expect(try clone.localOnly() == [try world.sha("feat/x", in: world.repo)])
    }

    @Test func removeDeletesTheFolder() throws {
        let clone = try FixClone.make(for: request(), git: git, root: world.root)
        clone.remove()
        #expect(!FileManager.default.fileExists(atPath: clone.path))
    }

    /// Review focus 2: a project path with a space and a double quote.
    @Test func survivesAnAwkwardProjectPath() throws {
        let odd = world.root + "/Acme \"Web\" repo"
        try FileManager.default.moveItem(atPath: world.repo, toPath: odd)
        let clone = try FixClone.make(for: FixRequest(title: "t", reason: nil, detail: nil, projectPath: odd, branch: "feat/x",
                                                      recreateRebase: false, retry: .createReview), git: git, root: world.root)
        defer { clone.remove() }
        #expect(try clone.tip("feat/x") == world.sha("feat/x", in: odd))
    }

    /// Review focus 4: only a dead owner's clone is swept; this process's live one stays.
    @Test func sweepRemovesOnlyDeadOwners() throws {
        let live = try FixClone.make(for: request(rebase: false), git: git, root: world.root)
        defer { live.remove() }
        let dead = world.root + "/" + FixClone.prefix + "dead"
        try FileManager.default.createDirectory(atPath: dead, withIntermediateDirectories: true)
        try #"{"pid":999999}"#.write(toFile: dead + "/" + FixClone.ownerFile, atomically: true, encoding: .utf8)
        let unrelated = world.root + "/aiterm-rebase-keep"
        try FileManager.default.createDirectory(atPath: unrelated, withIntermediateDirectories: true)
        FixClone.sweep(root: world.root)
        #expect(!FileManager.default.fileExists(atPath: dead))
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(FileManager.default.fileExists(atPath: unrelated))
    }

    /// No identity configured anywhere: the clone still lets the agent commit.
    @Test func theCloneHasACommitIdentity() throws {
        let clone = try FixClone.make(for: request(rebase: false), git: git, root: world.root)
        defer { clone.remove() }
        #expect(!(try git.run(["config", "user.email"], in: clone.path)).isEmpty)
    }
}
