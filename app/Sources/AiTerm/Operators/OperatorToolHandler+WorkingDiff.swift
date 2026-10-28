import Foundation
import AiTermCore

extension OperatorToolHandler {
    /// Tracked index/worktree edits and a bounded set of untracked patches. Git reads symlinks as
    /// links, so a new link never makes this read the target outside the worktree.
    nonisolated static func workingDiff(in path: String, git: any GitRunning) throws -> (text: String, truncated: Bool) {
        var text = try git.run(["diff", "--no-ext-diff", "--no-textconv", "HEAD", "--"], in: path)
        let names = try git.run(["ls-files", "--others", "--exclude-standard", "-z"], in: path).split(separator: "\0")
        var truncated = names.count > 20
        for name in names.prefix(20) {
            guard text.count < 80_000 else { truncated = true; break }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path + "/" + String(name)),
                  let kind = attributes[.type] as? FileAttributeType,
                  kind == .typeRegular || kind == .typeSymbolicLink,
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 128 * 1024 else {
                truncated = true
                continue
            }
            do {
                text += "\n" + (try git.run(["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--", "/dev/null", String(name)], in: path))
            } catch let error as GitError where error.code == 1 && !error.timedOut {
                // --no-index returns 1 when it found a patch, with that patch on stdout.
                text += "\n" + error.stdout
                if error.stdout.count >= GitError.stdoutLimit { truncated = true }
            } catch {
                truncated = true
            }
        }
        if text.count > 80_000 { text = String(text.prefix(80_000)); truncated = true }
        return (text, truncated)
    }
}
