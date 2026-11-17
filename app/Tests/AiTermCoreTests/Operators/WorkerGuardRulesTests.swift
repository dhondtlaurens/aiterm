import Foundation
import Testing
@testable import AiTermCore

@Suite struct WorkerGuardRulesTests {
    let branch = "feat/pay-1"
    @Test func aDefaultBranchIsRecognisedUnderAnySpelling() {
        let scope = WorkerGuard.Scope(task: UUID(), worktree: "/repo/work", branch: "main",
                                      remote: "git@git.example:shop/web.git", allowsPush: true)
        for spelling in ["Main", "MAIN", "refs/heads/main", "refs/heads/Main"] {
            #expect(WorkerGuard.pushDenial([], scope: scope, remote: scope.remote, head: String(repeating: "a", count: 40),
                defaultBranch: spelling, protection: .unprotected, isAncestor: { _, _ in true }) != nil)
        }
        #expect(WorkerGuard.shortBranch("refs/heads/feat/x") == "feat/x")
    }
    @Test(arguments: [
        "git push --no-verify", "git push -f origin HEAD", "git push --force-with-lease origin HEAD",
        "git -C /repo push origin +HEAD:feat/pay-1", "git push origin HEAD:main", "git push origin other",
        "git push --all", "git push --mirror", "git push --delete origin feat/pay-1", "git merge main",
        "gh pr merge 4", "glab mr accept 4", "sh -c 'git push --no-verify'", "echo $(git push -f)",
        "git -c alias.send='push --no-verify' send", "gh api -X PUT repos/a/b/pulls/4/merge",
        "gh api graphql -f 'query=mutation { mergePullRequest(input: {}) { clientMutationId } }'",
        "glab api graphql -f 'query=mutation { mergeRequestAccept(input: {}) { errors } }'",
    ]) func unsafePublishingIsRefusedBeforeTheCommandRuns(_ command: String) {
        #expect(WorkerGuard.commandDenial(command, branch: branch, allowsPush: true) != nil)
    }
    @Test(arguments: [
        "git status", "git commit -m 'Fix retries'", "git push -u origin HEAD", "git push origin feat/pay-1",
        "git push origin HEAD:refs/heads/feat/pay-1", "gh pr create --draft --title 'Fix retries'",
        "glab mr create --draft", "gh api repos/a/b/pulls/4/merge -X GET",
        "gh api repos/a/b/issues/4/comments -f 'body=Please avoid mergePullRequest here.'",
        "gh api graphql -f 'query=mutation { addComment(input: {body: \"mergePullRequest\"}) { clientMutationId } }'", "gh pr comment 4 --body 'Please review.'", "echo 'git push --force'",
    ]) func workerCanCommitAndPublishItsOwnBranch(_ command: String) {
        #expect(WorkerGuard.commandDenial(command, branch: branch, allowsPush: true) == nil)
    }
    @Test func currentWorkersStillCannotPushBeforeActivation() {
        #expect(WorkerGuard.commandDenial("git push origin HEAD", branch: branch, allowsPush: false) != nil)
        #expect(WorkerGuard.commandDenial("gh pr create --draft", branch: branch, allowsPush: false) != nil)
    }
    @Test func thePushHookChecksEveryRefAndRequiresCurrentHostAndFastForwardEvidence() throws {
        let head = String(repeating: "a", count: 40), old = String(repeating: "b", count: 40)
        let scope = WorkerGuard.Scope(task: UUID(), worktree: "/repo/work", branch: branch, remote: "git@git.example:shop/web.git", allowsPush: true)
        let record = "refs/heads/feat/pay-1 \(head) refs/heads/feat/pay-1 \(old)\n"
        let pushes = try WorkerGuard.pushes(record)
        #expect(try WorkerGuard.pushDenial(pushes, scope: scope, remote: "https://git.example/shop/web.git", head: head,
            defaultBranch: "main", protection: .unprotected, isAncestor: { $0 == old && $1 == head }) == nil)
        #expect(try WorkerGuard.pushDenial(pushes, scope: scope, remote: scope.remote, head: head,
            defaultBranch: branch, protection: .unprotected, isAncestor: { _, _ in true }) != nil)
        #expect(try WorkerGuard.pushDenial(pushes, scope: scope, remote: scope.remote, head: head,
            defaultBranch: "main", protection: .protected("a group rule"), isAncestor: { _, _ in true }) != nil)
        #expect(try WorkerGuard.pushDenial(pushes, scope: scope, remote: scope.remote, head: head,
            defaultBranch: "main", protection: .unprotected, isAncestor: { _, _ in false }) != nil)
        #expect(try WorkerGuard.pushDenial(pushes, scope: scope, remote: "git@other.example:shop/web.git", head: head,
            defaultBranch: "main", protection: .unprotected, isAncestor: { _, _ in true }) != nil)
        let foreign = try WorkerGuard.pushes(record + "refs/heads/feat/pay-1 \(head) refs/heads/main \(old)\n")
        #expect(try WorkerGuard.pushDenial(foreign, scope: scope, remote: scope.remote, head: head,
            defaultBranch: "main", protection: .unprotected, isAncestor: { _, _ in true }) != nil)
        #expect(throws: (any Error).self) { try WorkerGuard.pushes("a malformed line") }
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
        ("tmp/a/origin", "/tmp/a/origin", false),
        ("git@host:team/.git", "git@host:team", false),
    ])
    func twoUrlsAreTheSamePlaceWhenHostAndPathAre(a: String, b: String, same: Bool) {
        #expect(WorkerGuard.sameLocation(a, b) == same)
        #expect(WorkerGuard.sameLocation(b, a) == same)
    }
}
