import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct MergedBranchCheckTests {
    @Test func aSymbolicLocalRefNeverDeletesItsTarget() async throws {
        let git = GitRunner.hermetic()
        let path = try GitFixture.makeRepo(prefix: "close-symbolic", git: git)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sha = try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        try git.run(["symbolic-ref", "refs/heads/alias", "refs/heads/main"], in: path)
        _ = await MergedBranchCheck.delete(branch: "alias", acceptedSHA: sha, end: .mergeLocal,
                                                publication: nil, path: path, git: git, saveDeletion: { true })
        #expect(try git.run(["rev-parse", "refs/heads/main"], in: path).trimmingCharacters(in: .whitespacesAndNewlines) == sha)
    }

    @Test func fetchesOriginDefaultAndNeverDeletesTheRemoteBranch() async throws {
        let git = GitRunner.hermetic()
        let remote = try GitFixture.makeRepo(prefix: "close-origin", git: git)
        let local = try GitFixture.folder("close-local")
        defer { try? FileManager.default.removeItem(atPath: local); try? FileManager.default.removeItem(atPath: remote) }
        try git.run(["clone", remote, local], in: "/")
        try git.run(["commit", "--allow-empty", "-m", "accepted"], in: remote)
        let sha = try git.run(["rev-parse", "HEAD"], in: remote).trimmingCharacters(in: .whitespacesAndNewlines)
        try git.run(["branch", "task", sha], in: remote)
        try git.run(["fetch", "origin", "task"], in: local)
        try git.run(["branch", "task", sha], in: local)
        #expect(await MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .merge, publication: nil, path: local, git: git, saveDeletion: { true }))
        #expect(try git.run(["rev-parse", "refs/heads/task"], in: remote).trimmingCharacters(in: .whitespacesAndNewlines) == sha)
    }

    @Test func aFailedFetchKeepsTheBranch() async throws {
        let git = GitRunner.hermetic()
        let path = try GitFixture.makeRepo(prefix: "close-fetch-failure", git: git)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try git.run(["checkout", "-b", "task"], in: path)
        try git.run(["commit", "--allow-empty", "-m", "work"], in: path)
        let sha = try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        try git.run(["checkout", "main"], in: path)
        try git.run(["remote", "add", "origin", path + "/missing.git"], in: path)
        // Even a tracking ref that looks merged is not proof after a failed fetch.
        try git.run(["update-ref", "refs/remotes/origin/main", sha], in: path)
        #expect(await !MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .merge, publication: nil, path: path, git: git, saveDeletion: { true }))
        #expect(try git.run(["rev-parse", "refs/heads/task"], in: path).trimmingCharacters(in: .whitespacesAndNewlines) == sha)
    }

    @Test(arguments: [["worktree", "list"], ["remote", "get-url"], ["update-ref"]])
    func aFailedBranchCheckKeepsTheBranch(command: [String]) async throws {
        let git = GitRunner.hermetic()
        let path = try GitFixture.makeRepo(prefix: "close-check-failure", git: git)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try git.run(["checkout", "-b", "task"], in: path)
        try git.run(["commit", "--allow-empty", "-m", "work"], in: path)
        let sha = try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        try git.run(["checkout", "main"], in: path)
        if command == ["update-ref"] { try git.run(["merge", "--ff-only", "task"], in: path) }
        #expect(await !MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .merge, publication: nil,
                                                 path: path, git: BranchFailureGit(command: command), saveDeletion: { true }))
        #expect(try git.run(["rev-parse", "refs/heads/task"], in: path).trimmingCharacters(in: .whitespacesAndNewlines) == sha)
    }

    @Test(arguments: [false, true]) func deletionRequiresItsRecordSavedAndRemovesBranchConfig(saved: Bool) async throws {
        let git = GitRunner.hermetic()
        let path = try GitFixture.makeRepo(prefix: "close-deletion-save", git: git)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sha = try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        try git.run(["branch", "task", sha], in: path)
        try git.run(["config", "branch.task.remote", "origin"], in: path)
        try git.run(["config", "branch.task.merge", "refs/heads/task"], in: path)
        let deleted = await MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .mergeLocal, publication: nil,
                                                      path: path, git: git, saveDeletion: { saved })
        #expect(deleted == saved)
        #expect(try git.run(["branch", "--list", "task"], in: path).isEmpty == saved)
        #expect((try git.ask(["config", "--get", "branch.task.remote"], in: path, none: [1]) == nil) == saved)
    }

    @Test func aWorktreeThatTakesTheBranchAsItIsDeletedGetsItBack() async throws {
        let git = GitRunner.hermetic()
        let path = try GitFixture.makeRepo(prefix: "close-worktree-race", git: git)
        let checkout = try GitFixture.folder("close-worktree-race-checkout")
        defer { try? FileManager.default.removeItem(atPath: path); try? FileManager.default.removeItem(atPath: checkout) }
        let sha = try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        try git.run(["branch", "task", sha], in: path)
        try git.run(["config", "branch.task.remote", "origin"], in: path)
        let racing = WorktreeRacingGit(branch: "task", checkout: checkout + "/task")
        #expect(await !MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .mergeLocal, publication: nil,
                                                 path: path, git: racing, saveDeletion: { true }))
        #expect(try git.run(["rev-parse", "refs/heads/task"], in: path).trimmingCharacters(in: .whitespacesAndNewlines) == sha)
        #expect(try git.run(["config", "--get", "branch.task.remote"], in: path).trimmingCharacters(in: .whitespacesAndNewlines) == "origin")
    }

    @Test func deletesOnlyTheAcceptedMergedHeadIncludingSquashMerges() async throws {
        let git = GitRunner.hermetic()
        let path = try GitFixture.makeRepo(prefix: "auto-close-branch", git: git)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try git.run(["checkout", "-b", "task"], in: path)
        try "task work".write(toFile: path + "/work", atomically: true, encoding: .utf8)
        try git.run(["add", "work"], in: path)
        try git.run(["commit", "-m", "task"], in: path)
        let sha = try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        try git.run(["checkout", "main"], in: path)
        #expect(await !MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .merge, publication: nil, path: path, git: git, saveDeletion: { true }))
        try git.run(["merge", "--squash", "task"], in: path)
        try git.run(["commit", "-m", "squash"], in: path)
        #expect(try git.ask(["merge-base", "--is-ancestor", sha, "main"], in: path, none: [1]) == nil)
        var publication = TaskPublication()
        publication.merged = true
        publication.mergedHead = sha
        // A host-confirmed squash merge need not have the accepted commit as an ancestor.
        #expect(await !MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .commit, publication: publication, path: path, git: git, saveDeletion: { true }))
        #expect(await !MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .draftMR, publication: publication, path: path, git: git, saveDeletion: { true }))
        try git.run(["update-ref", "refs/heads/task", "main"], in: path)
        #expect(await !MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .merge, publication: publication, path: path, git: git, saveDeletion: { true }))
        try git.run(["update-ref", "refs/heads/task", sha], in: path)
        #expect(await MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .merge, publication: publication, path: path, git: git, saveDeletion: { true }))
        #expect(try git.ask(["rev-parse", "--verify", "refs/heads/task"], in: path, none: [128]) == nil)
        try git.run(["branch", "task", sha], in: path)
        try git.run(["merge", "--no-edit", "task"], in: path)
        #expect(await MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .mergeLocal, publication: nil, path: path, git: git, saveDeletion: { true }))
    }
}

private struct BranchFailureGit: GitRunning {
    let command: [String]
    let inner = GitRunner.hermetic()
    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        if args.starts(with: command) { throw GitError(args: args, code: 128, stderr: "Cannot read or lock ref") }
        return try inner.run(args, in: dir, timeout: timeout, environment: environment)
    }
}

/// Checks `branch` out in a new worktree just before the deletion's update-ref, as a racing `git worktree add` would.
private struct WorktreeRacingGit: GitRunning {
    let branch: String, checkout: String
    let inner = GitRunner.hermetic()
    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        if args.starts(with: ["update-ref", "--no-deref", "-d"]) {
            _ = try inner.run(["worktree", "add", checkout, branch], in: dir, timeout: timeout, environment: environment)
        }
        return try inner.run(args, in: dir, timeout: timeout, environment: environment)
    }
}
