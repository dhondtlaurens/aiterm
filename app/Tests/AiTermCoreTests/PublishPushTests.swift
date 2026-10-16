import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// finish_task's push: the accepted commit, to the task's own branch, never forced, never the default branch.
@Suite(.blocking) struct PublishPushTests {
    let git = GitRunner.hermetic()

    @Test func theAcceptedCommitIsPushedToTheTasksOwnBranchAndARepeatPushesNothing() throws {
        let (path, origin, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        let repo = Repository(path, git: git)
        try repo.push(sha, as: "feat/pluto-231", defaultBranch: "main")
        #expect(try git.run(["rev-parse", "refs/heads/feat/pluto-231"], in: origin) == sha)
        try repo.push(sha, as: "feat/pluto-231", defaultBranch: "main")
        #expect(try git.run(["rev-parse", "refs/heads/feat/pluto-231"], in: origin) == sha)
    }

    @Test func theAcceptedCommitIsPushedNotTheBranchTip() throws {
        let (path, origin, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        try git.run(["commit", "--allow-empty", "-q", "-m", "after acceptance"], in: path)
        try Repository(path, git: git).push(sha, as: "feat/pluto-231", defaultBranch: "main")
        #expect(try git.run(["rev-parse", "refs/heads/feat/pluto-231"], in: origin) == sha)
    }

    @Test func aPushIsNeverForced() throws {
        let (path, origin, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        let repo = Repository(path, git: git)
        try repo.push(sha, as: "feat/pluto-231", defaultBranch: "main")
        try git.run(["reset", "-q", "--hard", "main"], in: path)
        try git.run(["commit", "--allow-empty", "-q", "-m", "rewritten"], in: path)
        let rewritten = try git.run(["rev-parse", "HEAD"], in: path)
        #expect(throws: GitError.self) { try repo.push(rewritten, as: "feat/pluto-231", defaultBranch: "main") }
        #expect(try git.run(["rev-parse", "refs/heads/feat/pluto-231"], in: origin) == sha, "origin keeps its commit")
    }

    @Test func theDefaultBranchIsNeverPushed() throws {
        let (path, origin, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        let mainBefore = try git.run(["rev-parse", "refs/heads/main"], in: origin)
        #expect(throws: PublishRefusal.defaultBranch("main")) {
            try Repository(path, git: git).push(sha, as: "main", defaultBranch: "main")
        }
        #expect(try git.run(["rev-parse", "refs/heads/main"], in: origin) == mainBefore)
    }

    @Test(arguments: ["main", "Main", "MAIN", "refs/heads/main", "refs/heads/Main", "HEAD", "head"])
    func noSpellingOfTheDefaultBranchIsPushed(spelling: String) throws {
        let (path, origin, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        let before = try git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: origin)
        #expect(throws: PublishRefusal.defaultBranch("main")) {
            try Repository(path, git: git).push(sha, as: spelling, defaultBranch: "main")
        }
        #expect(try git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: origin) == before, "origin is untouched")
    }

    @Test func aDefaultBranchWithSlashesIsCaseFoldedToo() throws {
        let (path, _, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        #expect(throws: PublishRefusal.defaultBranch("release/Main")) {
            try Repository(path, git: git).push(sha, as: "RELEASE/main", defaultBranch: "release/Main")
        }
    }

    @Test(arguments: ["", "-f", "--force", "--mirror", "-d", "a b", "a..b", "x~1", "x:y", "x^", "a*", "a?", "a[", "a\\b", "@{-1}", "@", "end.", "x.lock", "/x", "x/", "a//b"])
    func aNameGitRefusesOrAnOptionIsNeverPushed(name: String) throws {
        let (path, origin, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        let before = try git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: origin)
        let refusal = #expect(throws: PublishRefusal.self) {
            try Repository(path, git: git).push(sha, as: name, defaultBranch: "main")
        }
        #expect(refusal == .invalidBranch(name))
        #expect(try git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: origin) == before)
    }

    @Test(arguments: ["", "HEAD", "main", "-f", "--all", "abc", "feat/pluto-231", "zz" + String(repeating: "0", count: 38),
                      String(repeating: "0", count: 40) + ":refs/heads/main"])
    func onlyACommitIdIsPushed(sha: String) throws {
        let (path, origin, _) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        let before = try git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: origin)
        let refusal = #expect(throws: PublishRefusal.self) {
            try Repository(path, git: git).push(sha, as: "feat/pluto-231", defaultBranch: "main")
        }
        #expect(refusal == .invalidCommit(sha))
        #expect(try git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: origin) == before)
    }

    @Test func theRefspecIsExactlyTheCommitToTheBranchWithNothingThatForcesOrWidens() throws {
        let (path, _, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        let recorder = RecordingGitRunner(forwardingTo: git)
        try Repository(path, git: recorder).push(sha, as: "feat/pluto-231", defaultBranch: "main")
        let push = try #require(recorder.calls.first { $0.args.contains("push") })
        #expect(push.timeout == Repository.pushTimeout)
        #expect(Repository.pushTimeout == 300)
        let args = push.args
        let verb = try #require(args.firstIndex(of: "push"))
        #expect(Array(args[verb...]) == ["push", "--porcelain", "origin", "\(sha):refs/heads/feat/pluto-231"])
        for flag in ["--force", "-f", "--force-with-lease", "--mirror", "--all", "--tags", "--delete", "--prune"] { #expect(!args.contains(flag)) }
        #expect(!args.contains { $0.hasPrefix("+") || $0.hasPrefix("--force") })
        #expect(recorder.calls.filter { $0.args.contains("push") }.count == 1)
    }

    @Test func aMirrorConfiguredOnOriginDoesNotWidenThePush() throws {
        let (path, origin, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        try git.run(["branch", "other", "main"], in: path)
        try git.run(["config", "remote.origin.mirror", "true"], in: path)
        try Repository(path, git: git).push(sha, as: "feat/pluto-231", defaultBranch: "main")
        let refs = try git.run(["for-each-ref", "--format=%(refname)"], in: origin)
        #expect(refs.split(separator: "\n").sorted() == ["refs/heads/feat/pluto-231", "refs/heads/main"])
    }

    @Test func withoutOriginNothingIsPushed() throws {
        let (path, _, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        try git.run(["remote", "remove", "origin"], in: path)
        #expect(throws: PublishRefusal.noOrigin) { try Repository(path, git: git).push(sha, as: "feat/pluto-231", defaultBranch: "main") }
    }

    @Test func aBranchsTipAndWhatItContains() throws {
        let (path, _, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        let repo = Repository(path, git: git)
        #expect(try repo.tip(of: "feat/pluto-231") == sha)
        #expect(try repo.tip(of: "feat/none") == nil)
        let main = try #require(try repo.tip(of: "main"))
        #expect(try repo.contains(main, in: sha))
        #expect(try !repo.contains(sha, in: main))
    }

    @Test func eachRefusalHasItsLine() {
        #expect(PublishRefusal.defaultBranch("main").errorDescription == "AiTerm never pushes to the default branch, main.")
        #expect(PublishRefusal.noOrigin.errorDescription == "The project has no origin to push to.")
        #expect(PublishRefusal.invalidBranch("-f").errorDescription == "-f is not a branch name AiTerm can push to.")
        #expect(PublishRefusal.invalidCommit("main").errorDescription == "main is not a full commit id.")
    }
}
