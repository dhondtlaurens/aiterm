import Foundation
import Testing
@testable import AiTermCore

@Suite struct WorkerGuardRulesTests {
    let branch = "feat/pay-1"
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
}
