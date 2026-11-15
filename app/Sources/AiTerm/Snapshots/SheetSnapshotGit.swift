import Foundation
import AiTermCore

#if DEBUG
/// Read-only answers for creation-sheet fixtures. Every unlisted operation fails closed.
struct SheetSnapshotGit: GitRunning {
    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        if args == ["for-each-ref", "--format=%(refname)", "--sort=-committerdate", "refs/heads", "refs/remotes/origin"] {
            return ["main", "feat-gift-card", "chore-drop-cdn-origin"].map { "refs/heads/" + $0 }.joined(separator: "\n")
        }
        if args == ["symbolic-ref", "refs/remotes/origin/HEAD"] { return "refs/remotes/origin/main" }
        throw GitError(args: args, code: 128, stderr: "No other repository read in the sheet fixture")
    }
}
#endif
