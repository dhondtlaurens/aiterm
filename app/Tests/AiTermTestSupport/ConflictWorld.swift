import Foundation
import AiTermCore

/// An origin, the project's clone of it (`repo`) and a teammate's (`other`), where `repo`'s
/// `feat/x` and origin's diverge with a conflict in `config.ts`: `repo` committed “mine”, the
/// teammate force-pushed “theirs” over the same line. `main` is shared and clean.
struct ConflictWorld {
    let root: String, remote: String, repo: String, other: String
    let git: any GitRunning

    init(git: any GitRunning, branch: String = "feat/x") throws {
        root = try GitFixture.folder("fixworld-")
        remote = root + "/remote.git"; repo = root + "/repo"; other = root + "/other"
        self.git = git
        try git.run(["init", "-q", "--bare", "-b", "main", remote], in: root)
        try git.run(["clone", "-q", remote, repo], in: root)
        try commit("init", file: "config.ts", contents: "topic=a\n", in: repo)
        try git.run(["push", "-q", "origin", "main"], in: repo)
        try git.run(["checkout", "-q", "-b", branch], in: repo)
        try git.run(["push", "-q", "-u", "origin", branch], in: repo)
        try git.run(["clone", "-q", remote, other], in: root)
        try git.run(["checkout", "-q", branch], in: other)
        try commit("theirs", file: "config.ts", contents: "topic=theirs\n", in: other)
        try git.run(["push", "-q", "origin", branch], in: other)
        try commit("mine", file: "config.ts", contents: "topic=mine\n", in: repo)
        try git.run(["fetch", "-q", "origin"], in: repo)
        try git.run(["checkout", "-q", "main"], in: repo)   // the branch is checked out nowhere, as a review's is
    }

    func commit(_ message: String, file: String, contents: String, in dir: String) throws {
        try contents.write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
        try git.run(["add", file], in: dir)
        try git.run(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", message], in: dir)
    }

    func sha(_ ref: String, in dir: String) throws -> String { try git.run(["rev-parse", ref], in: dir) }

    func removeAll() { try? FileManager.default.removeItem(atPath: root) }
}
