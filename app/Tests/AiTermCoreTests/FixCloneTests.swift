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

    /// C1's second guard: every git AiTerm runs in a made clone has fsmonitor and hooks off on its
    /// command line, which outranks whatever the clone's config says.
    @Test func everyGitInTheCloneRunsWithFsmonitorAndHooksOff() throws {
        let recording = RecordingGitRunner(forwardingTo: git)
        let clone = try FixClone.make(for: request(rebase: false), git: recording, root: world.root)
        defer { clone.remove() }
        let made = recording.calls.count
        _ = try clone.tip("feat/x")
        _ = try clone.branchTips()
        _ = try clone.localOnly()
        try FixGuard.check(clone, proposal: FixProposal(headline: "h", why: "w", steps: ["s"], moves: ["feat/x"], drops: [], verify: nil),
                           before: clone.branchTips())
        let after = recording.calls.dropFirst(made)
        #expect(after.count > 4)
        for call in after {
            #expect(call.args.starts(with: ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]), "\(call.args)")
        }
    }

    /// I2: a person who signs every commit. Signing cannot work in either agent's sandbox, and a
    /// signer that fails stops the recreated rebase at a commit with no conflict, which `make`
    /// would take for the conflict. The clone signs nothing, so the rebase stops on the conflict.
    @Test func aSigningSetupNeitherSignsNorStopsTheRecreatedRebase() throws {
        // `feat/x` with a commit that does not conflict before the one that does.
        try git.run(["checkout", "-q", "feat/x"], in: world.repo)
        try git.run(["reset", "-q", "--hard", "HEAD~1"], in: world.repo)
        try world.commit("first", file: "first.txt", contents: "x\n", in: world.repo)
        try world.commit("mine", file: "config.ts", contents: "topic=mine\n", in: world.repo)
        try git.run(["checkout", "-q", "main"], in: world.repo)
        let global = world.root + "/signing.gitconfig"
        try "[commit]\n\tgpgSign = true\n[tag]\n\tgpgSign = true\n[gpg]\n\tprogram = /usr/bin/false\n"
            .write(toFile: global, atomically: true, encoding: .utf8)
        let signing = GitRunner(environment: HermeticGit.environment.merging(["GIT_CONFIG_GLOBAL": global]) { $1 },
                                ignoringInherited: { $0.hasPrefix("GIT_") })
        let clone = try FixClone.make(for: request(), git: signing, root: world.root)
        defer { clone.remove() }
        #expect(try git.run(["status", "--porcelain"], in: clone.path).contains("UU config.ts"), "stopped on the conflict")
        #expect(try git.run(["config", "commit.gpgSign"], in: clone.path) == "false")
        #expect(try git.run(["config", "tag.gpgSign"], in: clone.path) == "false")
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
        try FileManager.default.createDirectory(atPath: dead + "/.git", withIntermediateDirectories: true)
        try #"{"pid":999999}"#.write(toFile: dead + "/" + FixClone.ownerFile, atomically: true, encoding: .utf8)
        let unrelated = world.root + "/aiterm-rebase-keep"
        try FileManager.default.createDirectory(atPath: unrelated, withIntermediateDirectories: true)
        FixClone.sweep(root: world.root)
        #expect(!FileManager.default.fileExists(atPath: dead))
        #expect(FileManager.default.fileExists(atPath: live.path))
        #expect(FileManager.default.fileExists(atPath: unrelated))
    }

    /// The owner file is inside `.git`, where the agent's `git add -A` and `git clean` never reach it.
    @Test func theOwnerFileIsInsideDotGit() throws {
        let clone = try FixClone.make(for: request(rebase: false), git: git, root: world.root)
        defer { clone.remove() }
        #expect(FileManager.default.fileExists(atPath: clone.path + "/.git/aiterm-fix-owner"))
        #expect(try git.run(["status", "--porcelain", "--ignored"], in: clone.path).isEmpty)
    }

    private func ownerless(_ name: String, ownerJSON: String? = nil, age: TimeInterval = 0) throws -> String {
        let dir = world.root + "/" + FixClone.prefix + name
        try FileManager.default.createDirectory(atPath: dir + "/.git", withIntermediateDirectories: true)
        if let ownerJSON { try ownerJSON.write(toFile: dir + "/" + FixClone.ownerFile, atomically: true, encoding: .utf8) }
        let then = Date(timeIntervalSinceNow: -age)
        try FileManager.default.setAttributes([.creationDate: then, .modificationDate: then], ofItemAtPath: dir)
        return dir
    }

    @Test func aYoungOwnerlessFolderIsKept() throws {
        let young = try ownerless("young")
        FixClone.sweep(root: world.root)
        #expect(FileManager.default.fileExists(atPath: young))
    }

    @Test func anOldOwnerlessFolderIsSwept() throws {
        let old = try ownerless("old", age: 16 * 60)
        FixClone.sweep(root: world.root)
        #expect(!FileManager.default.fileExists(atPath: old))
    }

    @Test func anOldFolderWithACorruptOwnerIsSweptAndAYoungOneKept() throws {
        let old = try ownerless("corrupt-old", ownerJSON: "not json", age: 16 * 60)
        let young = try ownerless("corrupt-young", ownerJSON: "not json")
        FixClone.sweep(root: world.root)
        #expect(!FileManager.default.fileExists(atPath: old))
        #expect(FileManager.default.fileExists(atPath: young))
    }

    @Test func aMissingLocalBranchFailsAndLeavesNothing() throws {
        let gone = FixRequest(title: "t", reason: nil, detail: nil, projectPath: world.repo, branch: "no/such",
                              recreateRebase: false, retry: .createReview)
        #expect(throws: FixRefusal.self) { try FixClone.make(for: gone, git: git, root: world.root) }
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: world.root)).contains { $0.hasPrefix(FixClone.prefix) })
    }

    /// A branch origin does not have: a clone with no rebase and no `origin/<branch>`.
    @Test func aLocalOnlyBranchMakesACloneWithoutARebaseOrAnOriginRef() throws {
        try git.run(["branch", "local-only", "main"], in: world.repo)
        let local = FixRequest(title: "t", reason: nil, detail: nil, projectPath: world.repo, branch: "local-only",
                               recreateRebase: true, retry: .createReview)
        let clone = try FixClone.make(for: local, git: git, root: world.root)
        defer { clone.remove() }
        #expect(clone.originTip == nil)
        #expect(try git.run(["for-each-ref", "refs/remotes"], in: clone.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: clone.path + "/.git/rebase-merge"))
        #expect(try clone.tip("local-only") == world.sha("local-only", in: world.repo))
    }

    /// The rebase was asked for but applies cleanly, so there is nothing stopped to hand the agent.
    @Test func aRebaseThatDoesNotStopRefusesAndLeavesNothing() throws {
        try git.run(["checkout", "-q", "-b", "feat/y", "main"], in: world.repo)
        try world.commit("y", file: "y.txt", contents: "y\n", in: world.repo)
        try git.run(["push", "-q", "-u", "origin", "feat/y"], in: world.repo)
        try git.run(["fetch", "-q", "origin"], in: world.other)
        try git.run(["checkout", "-q", "feat/y"], in: world.other)
        try world.commit("z", file: "z.txt", contents: "z\n", in: world.other)
        try git.run(["push", "-q", "origin", "feat/y"], in: world.other)
        try world.commit("y2", file: "y2.txt", contents: "y2\n", in: world.repo)
        try git.run(["fetch", "-q", "origin"], in: world.repo)
        try git.run(["checkout", "-q", "main"], in: world.repo)
        let clean = FixRequest(title: "t", reason: nil, detail: nil, projectPath: world.repo, branch: "feat/y",
                               recreateRebase: true, retry: .createReview)
        #expect(throws: FixRefusal.self) { try FixClone.make(for: clean, git: git, root: world.root) }
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: world.root)).contains { $0.hasPrefix(FixClone.prefix) })
    }

    /// No identity configured anywhere: the clone still lets the agent commit.
    @Test func theCloneHasACommitIdentity() throws {
        let clone = try FixClone.make(for: request(rebase: false), git: git, root: world.root)
        defer { clone.remove() }
        #expect(!(try git.run(["config", "user.email"], in: clone.path)).isEmpty)
    }
}
