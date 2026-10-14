import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The copy of a project a fix works in, so the agent never runs in the real repository. A
/// `--shared` clone writes no objects — it borrows the project's — so making one costs its
/// checkout. It has no remote (nothing to push to), no hooks, and the branch the fix is about with
/// origin's tip of it — plus the project's current branch, which a clone always starts on. The owner
/// file, inside `.git` so the agent's `git add -A` and `git clean` never see it, holds this
/// process's pid: a crashed run's clone is swept on the next launch and a live one never is.
public struct FixClone: Sendable {
    public static let prefix = "aiterm-fix-"
    static let ownerFile = ".git/aiterm-fix-owner"
    /// A folder with no readable owner is a clone still being made, or one that never got its file;
    /// it is swept only once it is this old.
    static let ownerlessGrace: TimeInterval = 15 * 60

    public let path: String
    public let branch: String
    public let startTip: String
    public let originTip: String?
    let git: any GitRunning

    public static func make(for request: FixRequest, git: any GitRunning,
                            root requestedRoot: String = NSTemporaryDirectory()) throws(FixRefusal) -> FixClone {
        // The real path (`/private/var/…`, not `/var/…`, which `resolvingSymlinksInPath` would keep):
        // a sandbox profile names the clone by it.
        let root = VerifySandbox.realPath(requestedRoot)
        let path = (root as NSString).appendingPathComponent(prefix + UUID().uuidString)
        do {
            let project = request.projectPath, branch = request.branch
            let quiet: [String: String] = ["GIT_LFS_SKIP_SMUDGE": "1"]
            let repository = Repository(project, git: git)
            guard let start = repository.sha("refs/heads/" + branch) else {
                throw FixRefusal.cloneFailed("there is no local “\(branch)”.")
            }
            let origin = repository.sha("refs/remotes/origin/" + branch)
            try git.run(["-c", "core.hooksPath=/dev/null", "clone", "-q", "--shared", "--no-checkout", "--no-tags", project, path],
                        in: root, timeout: GitRunner.checkoutTimeout, environment: quiet)
            try Data(#"{"pid":\#(getpid())}"#.utf8).write(to: URL(fileURLWithPath: path + "/" + ownerFile))
            try git.run(["remote", "remove", "origin"], in: path)
            // The exact commits recorded above, not the branch names: the clone holds what `startTip`
            // and `originTip` say even if the project's branch moves meanwhile.
            var refspecs = ["+\(start):refs/heads/\(branch)"]
            if let origin { refspecs.append("+\(origin):refs/remotes/origin/\(branch)") }
            try git.run(["-c", "core.hooksPath=/dev/null", "fetch", "-q", "--no-tags", "--update-head-ok", project] + refspecs, in: path)
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
                guard FileManager.default.fileExists(atPath: path + "/.git/rebase-merge") else {
                    throw FixRefusal.cloneFailed("“\(branch)” rebases onto origin without stopping, so there is no stopped rebase to fix.")
                }
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

    /// Clones whose owner is not alive — a run that crashed or was killed. Never by prefix alone: a
    /// folder with no readable owner is kept until it is `ownerlessGrace` old, as one mid-clone is.
    /// EPERM from `kill` means the pid exists but is another user's: alive.
    public static func sweep(root: String = NSTemporaryDirectory(), isAlive: (pid_t) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        for name in names where name.hasPrefix(prefix) {
            let dir = (root as NSString).appendingPathComponent(name)
            let owner = try? JSONDecoder().decode(Owner.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/" + ownerFile)))
            if let pid = owner?.pid {
                if isAlive(pid_t(pid)) { continue }
            } else if isYoung(dir) { continue }
            try? FileManager.default.removeItem(atPath: dir)
        }
    }

    /// Whether `dir` was made or changed within the grace; one whose dates cannot be read is young.
    private static func isYoung(_ dir: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: dir) else { return true }
        let latest = [attributes[.creationDate], attributes[.modificationDate]].compactMap { $0 as? Date }.max()
        return latest.map { Date().timeIntervalSince($0) < ownerlessGrace } ?? true
    }

    private struct Owner: Decodable { var pid: Int32 }
}
