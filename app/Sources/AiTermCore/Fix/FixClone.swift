import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The copy of a project a fix works in, so the agent never runs in the real repository. A
/// `--shared` clone writes no objects — it borrows the project's — so making one costs its
/// checkout. It has no remote (nothing to push to), no hooks, and only the branch the fix is about
/// and origin's tip of it. `owner` holds this process's pid, so a crashed run's clone is swept on
/// the next launch and a live one never is.
public struct FixClone: Sendable {
    public static let prefix = "aiterm-fix-"
    static let ownerFile = ".aiterm-fix-owner"

    public let path: String
    public let branch: String
    public let startTip: String
    public let originTip: String?
    let git: any GitRunning

    public static func make(for request: FixRequest, git: any GitRunning,
                            root: String = NSTemporaryDirectory()) throws(FixRefusal) -> FixClone {
        let path = (root as NSString).appendingPathComponent(prefix + UUID().uuidString)
        do {
            let project = request.projectPath, branch = request.branch
            let quiet: [String: String] = ["GIT_LFS_SKIP_SMUDGE": "1"]
            guard let start = Repository(project, git: git).sha("refs/heads/" + branch) else {
                throw FixRefusal.cloneFailed("there is no local “\(branch)”.")
            }
            let origin = Repository(project, git: git).sha("refs/remotes/origin/" + branch)
            try git.run(["-c", "core.hooksPath=/dev/null", "clone", "-q", "--shared", "--no-checkout", "--no-tags", project, path],
                        in: root, timeout: GitRunner.checkoutTimeout, environment: quiet)
            try Data(#"{"pid":\#(getpid())}"#.utf8).write(to: URL(fileURLWithPath: path + "/" + ownerFile))
            try git.run(["remote", "remove", "origin"], in: path)
            var refspecs = ["+refs/heads/\(branch):refs/heads/\(branch)"]
            if origin != nil { refspecs.append("+refs/remotes/origin/\(branch):refs/remotes/origin/\(branch)") }
            try git.run(["fetch", "-q", "--no-tags", "--update-head-ok", project] + refspecs, in: path)
            try git.run(["config", "core.hooksPath", "/dev/null"], in: path)
            try git.run(["config", "core.fsmonitor", "false"], in: path)
            let name = (try? git.run(["config", "user.name"], in: project)).flatMap { $0.isEmpty ? nil : $0 } ?? "AiTerm Fix"
            let email = (try? git.run(["config", "user.email"], in: project)).flatMap { $0.isEmpty ? nil : $0 } ?? "fix@aiterm.invalid"
            try git.run(["config", "user.name", name], in: path)
            try git.run(["config", "user.email", email], in: path)
            try git.run(["checkout", "-q", branch], in: path, timeout: GitRunner.checkoutTimeout, environment: quiet)
            if request.recreateRebase, origin != nil {
                // Expected to stop on the conflict: that stopped state is what the agent reads.
                _ = try? git.run(["rebase", "--no-autostash", "--no-update-refs", "--no-rebase-merges", "origin/" + branch],
                                 in: path, timeout: GitRunner.checkoutTimeout, environment: quiet)
            }
            return FixClone(path: path, branch: branch, startTip: start, originTip: origin, git: git)
        } catch let refusal as FixRefusal {
            try? FileManager.default.removeItem(atPath: path)
            throw refusal
        } catch {
            try? FileManager.default.removeItem(atPath: path)
            throw .cloneFailed(OperationIssue.reason(of: error))
        }
    }

    public func tip(_ branch: String) throws -> String { try git.run(["rev-parse", "refs/heads/" + branch], in: path) }

    /// Every local branch and its tip, for the “moved only what it said” check.
    public func branchTips() throws -> [String: String] {
        let lines = try git.run(["for-each-ref", "--format=%(refname:strip=2) %(objectname)", "refs/heads"], in: path)
        return Dictionary(lines.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }, uniquingKeysWith: { a, _ in a })
    }

    /// The start tip's commits origin's tip lacks, by sha.
    public func localOnly() throws -> Set<String> {
        guard let originTip else { return Set(try git.run(["rev-list", startTip], in: path).split(separator: "\n").map(String.init)) }
        return Set(try git.run(["rev-list", startTip, "^" + originTip], in: path).split(separator: "\n").map(String.init))
    }

    public func remove() { try? FileManager.default.removeItem(atPath: path) }

    /// Clones whose owner is not alive — a run that crashed or was killed. Never by prefix alone.
    /// EPERM from `kill` means the pid exists but is another user's: alive.
    public static func sweep(root: String = NSTemporaryDirectory(), isAlive: (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for name in names where name.hasPrefix(prefix) {
            let dir = (root as NSString).appendingPathComponent(name)
            let owner = try? JSONDecoder().decode(Owner.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/" + ownerFile)))
            if let pid = owner?.pid, isAlive(pid_t(pid)) { continue }
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    private struct Owner: Decodable { var pid: Int32 }
}
