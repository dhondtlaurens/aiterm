import Foundation
import AiTermCore

extension GitFixture {
    /// A repository on `main` whose origin is a bare repository beside it, holding `main`; and
    /// `branch`, checked out, one commit ahead, which origin does not have yet. The commit is returned.
    static func withOrigin(branch: String, git: any GitRunning = GitRunner.hermetic()) throws -> (path: String, origin: String, sha: String) {
        let origin = try folder("origin-")
        try git.run(["init", "--bare", "-q", "--initial-branch=main", origin], in: "/")
        let path = try makeRepo(prefix: "publish-", git: git)
        try git.run(["remote", "add", "origin", origin], in: path)
        try git.run(["push", "-q", "origin", "main"], in: path)
        try git.run(["switch", "-q", "-c", branch], in: path)
        try git.run(["commit", "--allow-empty", "-q", "-m", branch], in: path)
        return (path, origin, try git.run(["rev-parse", "HEAD"], in: path))
    }
}
