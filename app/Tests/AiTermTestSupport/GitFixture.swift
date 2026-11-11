import Foundation
import Synchronization
import AiTermCore

/// The repositories the git tests start from, made with hermetic git (``HermeticGit``).
enum GitFixture {
    // One seed per test host. Copies own their objects and refs: no shared alternates or hardlinks.
    final class Template: Sendable {
        private let cached = Mutex<String?>(nil)

        func path(build: () throws -> String) throws -> String {
            try cached.withLock { value in
                if let value { return value }
                let path = try build()
                value = path
                return path
            }
        }
    }
    private static let template = Template()

    /// A fresh folder in the temporary directory, named from `prefix`. Its real path, because git
    /// reports `/private/var/…` where Foundation says `/var/…`, and the two must agree.
    static func folder(_ prefix: String) throws -> String {
        try ScratchFolder.make(prefix).resolvingSymlinksInPath().path
    }

    /// A repository in `folder`, on `branch`, with one empty commit.
    static func initRepo(at folder: String, branch: String = "main", refFormat: String? = nil) throws {
        guard branch == "main", refFormat == nil else {
            return try initRepo(at: folder, branch: branch, refFormat: refFormat, git: GitRunner.hermetic())
        }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let seed = try template.path {
            let path = try self.folder("git-template-")
            try initRepo(at: path, git: GitRunner.hermetic())
            return path
        }
        try FileManager.default.copyItem(atPath: seed + "/.git", toPath: folder + "/.git")
    }

    /// An explicit runner keeps owning setup too, for tests of a git fault or a spawn count.
    static func initRepo(at folder: String, branch: String = "main", refFormat: String? = nil,
                         git: any GitRunning) throws {
        try git.run(["init", "--initial-branch=\(branch)", "-q"] + (refFormat.map { ["--ref-format=\($0)"] } ?? []) + [folder], in: "/")
        try git.run(["commit", "--allow-empty", "-q", "-m", "init"], in: folder)
    }

    /// `initRepo` in a fresh folder of its own.
    static func makeRepo(prefix: String, branch: String = "main", refFormat: String? = nil) throws -> String {
        let repo = try folder(prefix)
        try initRepo(at: repo, branch: branch, refFormat: refFormat)
        return repo
    }

    static func makeRepo(prefix: String, branch: String = "main", refFormat: String? = nil,
                         git: any GitRunning) throws -> String {
        let repo = try folder(prefix)
        try initRepo(at: repo, branch: branch, refFormat: refFormat, git: git)
        return repo
    }

    /// Main-actor fixtures await setup rather than running git while they hold the actor.
    static func makeRepoOffMain(prefix: String, branch: String = "main") async throws -> String {
        try await BackgroundWork.run { try makeRepo(prefix: prefix, branch: branch) }
    }
}
