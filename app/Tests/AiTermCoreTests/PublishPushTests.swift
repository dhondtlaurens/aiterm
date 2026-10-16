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
        #expect(Array(args[verb...]) == ["push", "--porcelain", "--no-follow-tags", "--no-recurse-submodules", "origin", "\(sha):refs/heads/feat/pluto-231"])
        #expect(Array(args[..<verb]).suffix(2) == ["-c", "push.pushOption="], "inherited push options are cleared")
        for flag in ["--force", "-f", "--force-with-lease", "--mirror", "--all", "--tags", "--delete", "--prune", "--no-verify"] { #expect(!args.contains(flag)) }
        #expect(!args.contains { $0.hasPrefix("+") || $0.hasPrefix("--force") })
        #expect(recorder.calls.filter { $0.args.contains("push") }.count == 1)
    }

    @Test func aMirrorConfiguredOnOriginDoesNotWidenThePush() throws {
        let (path, origin, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        try git.run(["branch", "other", "main"], in: path)
        try git.run(["config", "remote.origin.mirror", "true"], in: path)
        // git itself refuses a mirror with a refspec; either way nothing but the one branch can arrive.
        try? Repository(path, git: git).push(sha, as: "feat/pluto-231", defaultBranch: "main")
        let refs = try git.run(["for-each-ref", "--format=%(refname)"], in: origin)
        #expect(!refs.split(separator: "\n").contains("refs/heads/other"))
    }

    @Test func pushOptionsAndTagsFromTheConfigurationNeverReachTheRemote() throws {
        let (path, origin, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        // The remote records the push options it receives, and tells git it accepts them.
        let record = origin + "/push-options"
        try git.run(["config", "receive.advertisePushOptions", "true"], in: origin)
        let hook = origin + "/hooks/pre-receive"
        try "#!/bin/sh\necho \"${GIT_PUSH_OPTION_COUNT:-0} $GIT_PUSH_OPTION_0\" > '\(record)'\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        // The probe: the hook does see an option a push sends, so its silence below means something.
        try git.run(["push", "-q", "-o", "probe", "origin", "\(sha):refs/heads/probe"], in: path)
        #expect(try String(contentsOfFile: record, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "1 probe")
        try git.run(["update-ref", "-d", "refs/heads/probe"], in: origin)
        try FileManager.default.removeItem(atPath: record)

        try git.run(["tag", "-a", "v1", "-m", "v1", sha], in: path)
        try git.run(["config", "push.followTags", "true"], in: path)
        try git.run(["config", "push.pushOption", "merge_request.create"], in: path)
        try Repository(path, git: git).push(sha, as: "feat/pluto-231", defaultBranch: "main")

        let refs = try git.run(["for-each-ref", "--format=%(refname)"], in: origin)
        #expect(refs.split(separator: "\n").sorted() == ["refs/heads/feat/pluto-231", "refs/heads/main"], "no tag came along")
        #expect(try String(contentsOfFile: record, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "0", "no push option was sent")
    }

    @Test func aSubmoduleSettingDoesNotTurnThePushIntoSubmodulePushes() throws {
        let (path, origin, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        try git.run(["config", "push.recurseSubmodules", "on-demand"], in: path)
        try Repository(path, git: git).push(sha, as: "feat/pluto-231", defaultBranch: "main")
        #expect(try git.run(["rev-parse", "refs/heads/feat/pluto-231"], in: origin) == sha)
    }

    // MARK: Where the push goes

    /// A second bare repository, to see whether a push strays into it.
    private func elsewhere() throws -> String {
        let other = try GitFixture.folder("elsewhere-")
        try git.run(["init", "--bare", "-q", "--initial-branch=main", other], in: "/")
        return other
    }

    @Test func aSecondUrlOnOriginIsRefusedAndNothingIsPushedToEither() throws {
        let (path, origin, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        let other = try elsewhere()
        try git.run(["config", "--add", "remote.origin.url", other], in: path)
        let refusal = #expect(throws: PublishRefusal.self) { try Repository(path, git: git).push(sha, as: "feat/pluto-231", defaultBranch: "main") }
        guard case .pushDestination = refusal else { Issue.record("got \(String(describing: refusal))"); return }
        #expect(try git.run(["for-each-ref"], in: other) == "")
        #expect(try git.ask(["rev-parse", "--verify", "--quiet", "refs/heads/feat/pluto-231"], in: origin, none: [1]) == nil)
    }

    @Test func aPushUrlOnOriginIsRefusedAndNothingIsPushed() throws {
        let (path, origin, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        let other = try elsewhere()
        try git.run(["config", "remote.origin.pushurl", other], in: path)
        let refusal = #expect(throws: PublishRefusal.self) { try Repository(path, git: git).push(sha, as: "feat/pluto-231", defaultBranch: "main") }
        guard case .pushDestination = refusal else { Issue.record("got \(String(describing: refusal))"); return }
        #expect(try git.run(["for-each-ref"], in: other) == "")
        #expect(try git.ask(["rev-parse", "--verify", "--quiet", "refs/heads/feat/pluto-231"], in: origin, none: [1]) == nil)
    }

    @Test func aPushInsteadOfThatMovesThePushIsRefusedAndNothingIsPushed() throws {
        let (path, origin, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        let other = try elsewhere()
        try git.run(["config", "url.\(other).pushInsteadOf", origin], in: path)
        let refusal = #expect(throws: PublishRefusal.self) { try Repository(path, git: git).push(sha, as: "feat/pluto-231", defaultBranch: "main") }
        guard case .pushDestination = refusal else { Issue.record("got \(String(describing: refusal))"); return }
        #expect(try git.run(["for-each-ref"], in: other) == "")
        #expect(try git.ask(["rev-parse", "--verify", "--quiet", "refs/heads/feat/pluto-231"], in: origin, none: [1]) == nil)
    }

    @Test(arguments: [
        ("https://github.com/acme/app.git", "git@github.com:acme/app.git", true),
        ("https://github.com/acme/app", "ssh://git@github.com:22/acme/app.git/", true),
        ("https://GitHub.com/Acme/App.git", "git@github.com:acme/app", true),
        ("https://gitlab.com/acme/app.git", "git@gitlab.com:/acme/app.git", true),
        ("/tmp/a/origin", "file:///tmp/a/origin", true),
        ("/tmp/a/origin/", "/tmp/a/origin", true),
        ("https://github.com/acme/app.git", "https://github.com/acme/other.git", false),
        ("https://github.com/acme/app.git", "https://evil.example/acme/app.git", false),
        ("/tmp/a/origin", "/tmp/b/origin", false),
        ("/tmp/a/origin", "https://github.com/tmp/a/origin", false),
    ])
    func twoUrlsAreTheSamePlaceWhenHostAndPathAre(a: String, b: String, same: Bool) {
        #expect(Repository.sameLocation(a, b) == same)
        #expect(Repository.sameLocation(b, a) == same)
    }

    // MARK: Origin's own word

    @Test func originsOwnDefaultBranchIsNeverPushedWhateverTheCallerSays() throws {
        let (path, origin, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        try git.run(["push", "-q", "origin", "main:refs/heads/develop"], in: path)
        try git.run(["symbolic-ref", "HEAD", "refs/heads/develop"], in: origin)
        let before = try git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: origin)
        #expect(throws: PublishRefusal.defaultBranch("develop")) {
            try Repository(path, git: git).push(sha, as: "develop", defaultBranch: "main")
        }
        #expect(throws: PublishRefusal.defaultBranch("develop")) {
            try Repository(path, git: git).push(sha, as: "DEVELOP", defaultBranch: "main")
        }
        #expect(try git.run(["for-each-ref", "--format=%(refname) %(objectname)"], in: origin) == before)
    }

    @Test func aBranchThatIsAnotherNameForAnotherOnOriginIsRefused() throws {
        let (path, origin, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        try git.run(["symbolic-ref", "refs/heads/alias", "refs/heads/main"], in: origin)
        let mainBefore = try git.run(["rev-parse", "refs/heads/main"], in: origin)
        #expect(throws: PublishRefusal.symbolicBranch("alias")) {
            try Repository(path, git: git).push(sha, as: "alias", defaultBranch: "main")
        }
        #expect(try git.run(["rev-parse", "refs/heads/main"], in: origin) == mainBefore)
    }

    @Test func anOriginWhoseHeadCannotBeReadGetsNothing() throws {
        let (path, origin, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        try git.run(["symbolic-ref", "HEAD", "refs/heads/gone"], in: origin)
        #expect(throws: PublishRefusal.originUnreadable) {
            try Repository(path, git: git).push(sha, as: "feat/pluto-231", defaultBranch: "main")
        }
        #expect(try git.ask(["rev-parse", "--verify", "--quiet", "refs/heads/feat/pluto-231"], in: origin, none: [1]) == nil)
    }

    @Test func withNoDefaultBranchToCompareWithNothingIsPushed() throws {
        let (path, origin, sha) = try GitFixture.withOrigin(branch: "feat/pluto-231")
        for empty in ["", "refs/heads/"] {
            #expect(throws: PublishRefusal.unknownDefaultBranch) {
                try Repository(path, git: git).push(sha, as: "feat/pluto-231", defaultBranch: empty)
            }
        }
        #expect(try git.ask(["rev-parse", "--verify", "--quiet", "refs/heads/feat/pluto-231"], in: origin, none: [1]) == nil)
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
        #expect(PublishRefusal.unknownDefaultBranch.errorDescription == "AiTerm does not know the project's default branch, so it pushes nothing.")
        #expect(PublishRefusal.pushDestination("origin has 2 URLs to push to").errorDescription == "AiTerm pushes only to origin's own URL, and origin has 2 URLs to push to.")
        #expect(PublishRefusal.originUnreadable.errorDescription == "AiTerm could not read origin's default branch, so it pushes nothing.")
        #expect(PublishRefusal.symbolicBranch("alias").errorDescription == "The branch alias on origin is another name for a branch, so AiTerm pushes nothing to it.")
    }
}
