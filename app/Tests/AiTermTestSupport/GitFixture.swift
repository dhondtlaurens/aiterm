import Foundation
import AiTermCore

/// The repositories the git tests start from, made with hermetic git (``HermeticGit``).
enum GitFixture {
    /// A fresh folder in the temporary directory, named from `prefix`. Its real path, because git
    /// reports `/private/var/…` where Foundation says `/var/…`, and the two must agree.
    static func folder(_ prefix: String) throws -> String {
        let dir = NSTemporaryDirectory() + prefix + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
    }

    /// A repository in `folder`, on `branch`, with one empty commit.
    static func initRepo(at folder: String, branch: String = "main", refFormat: String? = nil,
                         git: any GitRunning = GitRunner.hermetic()) throws {
        try git.run(["init", "--initial-branch=\(branch)", "-q"] + (refFormat.map { ["--ref-format=\($0)"] } ?? []) + [folder], in: "/")
        try git.run(["commit", "--allow-empty", "-q", "-m", "init"], in: folder)
    }

    /// `initRepo` in a fresh folder of its own.
    static func makeRepo(prefix: String, branch: String = "main", refFormat: String? = nil,
                         git: any GitRunning = GitRunner.hermetic()) throws -> String {
        let repo = try folder(prefix)
        try initRepo(at: repo, branch: branch, refFormat: refFormat, git: git)
        return repo
    }
}
