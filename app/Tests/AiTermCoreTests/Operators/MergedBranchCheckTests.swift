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
        _ = try await MergedBranchCheck.delete(branch: "alias", acceptedSHA: sha, end: .mergeLocal,
                                                publication: nil, path: path, git: git)
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
        #expect(try await MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .merge, publication: nil, path: local, git: git))
        #expect(try git.run(["rev-parse", "refs/heads/task"], in: remote).trimmingCharacters(in: .whitespacesAndNewlines) == sha)
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
        #expect(try await !MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .merge, publication: nil, path: path, git: git))
        try git.run(["merge", "--squash", "task"], in: path)
        try git.run(["commit", "-m", "squash"], in: path)
        #expect(try git.ask(["merge-base", "--is-ancestor", sha, "main"], in: path, none: [1]) == nil)
        var publication = TaskPublication()
        publication.merged = true
        publication.mergedHead = sha
        // A host-confirmed squash merge need not have the accepted commit as an ancestor.
        #expect(try await !MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .commit, publication: publication, path: path, git: git))
        #expect(try await !MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .draftMR, publication: publication, path: path, git: git))
        try git.run(["update-ref", "refs/heads/task", "main"], in: path)
        #expect(try await !MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .merge, publication: publication, path: path, git: git))
        try git.run(["update-ref", "refs/heads/task", sha], in: path)
        #expect(try await MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .merge, publication: publication, path: path, git: git))
        #expect(try git.ask(["rev-parse", "--verify", "refs/heads/task"], in: path, none: [128]) == nil)
        try git.run(["branch", "task", sha], in: path)
        try git.run(["merge", "--no-edit", "task"], in: path)
        #expect(try await MergedBranchCheck.delete(branch: "task", acceptedSHA: sha, end: .mergeLocal, publication: nil, path: path, git: git))
    }
}
