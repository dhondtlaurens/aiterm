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
///
/// The agent can write the clone, `.git` included, and a `core.fsmonitor` or `filter.*.clean` that
/// AiTerm's own git read would run as the person, unsandboxed, with the network on. So that git is
/// `CloneGit`: it names the clone's `.git` and work tree itself — git never discovers a repository
/// the agent laid out — with fsmonitor and hooks off on its command line. And the settings `make`
/// leaves are kept (`settings`): every run of an agent or `verify` is followed by
/// `checkSettings()` before AiTerm runs git in the clone again.
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
    /// Every git AiTerm runs in the clone: `CloneGit`, whatever runner it was given.
    let git: any GitRunning
    /// The clone's settings as `make` left them (`settings(at:)`); nil for a clone that never had them read.
    let settings: Settings?

    init(path: String, branch: String, startTip: String, originTip: String?, git: any GitRunning, settings: Settings? = nil) {
        self.path = path; self.branch = branch; self.startTip = startTip; self.originTip = originTip
        self.git = CloneGit((git as? CloneGit)?.inner ?? git, clone: path); self.settings = settings
    }

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
            let clone = CloneGit(git, clone: path)
            try clone.run(["remote", "remove", "origin"], in: path)
            // The exact commits recorded above, not the branch names: the clone holds what `startTip`
            // and `originTip` say even if the project's branch moves meanwhile.
            var refspecs = ["+\(start):refs/heads/\(branch)"]
            if let origin { refspecs.append("+\(origin):refs/remotes/origin/\(branch)") }
            try clone.run(["fetch", "-q", "--no-tags", "--update-head-ok", project] + refspecs, in: path)
            try clone.run(["config", "core.hooksPath", "/dev/null"], in: path)
            try clone.run(["config", "core.fsmonitor", "false"], in: path)
            let name = (try? git.run(["config", "user.name"], in: project)).flatMap { $0.isEmpty ? nil : $0 } ?? "AiTerm Fix"
            let email = (try? git.run(["config", "user.email"], in: project)).flatMap { $0.isEmpty ? nil : $0 } ?? "fix@aiterm.invalid"
            try clone.run(["config", "user.name", name], in: path)
            try clone.run(["config", "user.email", email], in: path)
            // A fix's commits are unsigned: no signer works in either agent's sandbox, and one that
            // fails would stop the recreated rebase at a commit with no conflict, taken for the conflict.
            try clone.run(["config", "commit.gpgSign", "false"], in: path)
            try clone.run(["config", "tag.gpgSign", "false"], in: path)
            try clone.run(["checkout", "-q", branch], in: path, timeout: GitRunner.checkoutTimeout, environment: quiet)
            if request.recreateRebase, origin != nil {
                // Expected to stop on the conflict: that stopped state is what the agent reads.
                _ = try? clone.run(["rebase", "--no-autostash", "--no-update-refs", "--no-rebase-merges", "origin/" + branch],
                                   in: path, timeout: GitRunner.checkoutTimeout, environment: quiet)
                guard FileManager.default.fileExists(atPath: path + "/.git/rebase-merge") else {
                    throw FixRefusal.cloneFailed("“\(branch)” rebases onto origin’s without a conflict now, so there is no conflict left to fix.")
                }
            }
            // Last, once nothing of `make`'s writes the config again: the settings every later check compares with.
            guard let settings = Self.settings(at: path) else { throw FixRefusal.cloneFailed("its git settings could not be read.") }
            return FixClone(path: path, branch: branch, startTip: start, originTip: origin, git: clone, settings: settings)
        } catch let refusal as FixRefusal {
            try? FileManager.default.removeItem(atPath: path)
            throw refusal
        } catch {
            try? FileManager.default.removeItem(atPath: path)
            throw .cloneFailed(GitError.displayReason(of: error))
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

    /// Refuses unless the clone's git settings are exactly what `make` left. Called after every run
    /// of an agent or `verify`, before AiTerm's own git runs in the clone again.
    public func checkSettings() throws(FixRefusal) {
        guard let settings, Self.settings(at: path) == settings else { throw .settingsChanged }
    }

    /// What decides how AiTerm's git reads the clone, beyond the command line: `.git/config`, and
    /// the `shallow` file, which cuts history short (a project that is itself shallow has one).
    struct Settings: Equatable, Sendable {
        var config: Data
        var shallow: Data?
    }

    /// The most a settings file may hold; a clone's config is a few hundred bytes.
    static let settingsLimit = 1 << 20

    /// The clone's settings — or nil when git would not take them from these files: `.git` is no
    /// longer a plain folder (a symlink, or a gitfile naming another), a `commondir` file sends git
    /// to another repository's config and refs, or a file is not a regular one under the limit.
    static func settings(at path: String) -> Settings? {
        let dotGit = path + "/.git"
        var info = stat()
        guard lstat(dotGit, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              case .absent = entry(dotGit + "/commondir"),
              case .bytes(let config) = entry(dotGit + "/config") else { return nil }
        switch entry(dotGit + "/shallow") {
        case .absent: return Settings(config: config, shallow: nil)
        case .bytes(let shallow): return Settings(config: config, shallow: shallow)
        case nil: return nil
        }
    }

    private enum Entry { case absent, bytes(Data) }

    /// A regular file's bytes, read without following a symlink or waiting on a FIFO: `.absent` when
    /// nothing is at `path`, nil for anything else there — a symlink, a FIFO, a folder, a file over
    /// `settingsLimit`, or one that cannot be read.
    private static func entry(_ path: String) -> Entry? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno == ENOENT ? .absent : nil }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= settingsLimit else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // Again on what was opened: the file may have been swapped since the `lstat`.
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { return .bytes(data) }
            data.append(buffer, count: count)
            if data.count > settingsLimit { return nil }
        }
    }

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

/// Git in a fix's clone, as AiTerm itself runs it. The repository is named, never discovered:
/// `--git-dir` and `--work-tree` are the clone's own, so a broken `.git` fails with “not a git
/// repository” rather than git taking a layout the agent made at the root (or above it) for one, and
/// `safe.bareRepository=explicit` refuses any bare repository found by looking. Objects are read as
/// they are: no replace refs (`--no-replace-objects`) and no grafts (`GIT_GRAFT_FILE`), either of
/// which could hide a conflict marker or a dropped commit from the checks. Submodules are ignored
/// (`diff.ignoreSubmodules=all`): a populated one is a repository of the agent's, whose own filters
/// `status` would run; landing moves refs only, so their work trees say nothing it needs.
/// `core.fsmonitor` and `core.hooksPath` are off on the command line, which outranks the clone's
/// config — a second guard behind `checkSettings()` for the two settings that run a command on the
/// commands AiTerm uses. Grafts' deprecation hint is off, so it never ends up in a failure's sentence.
struct CloneGit: GitRunning {
    let inner: any GitRunning
    /// The clone's absolute path.
    let clone: String
    init(_ inner: any GitRunning, clone: String) { self.inner = inner; self.clone = clone }

    var flags: [String] {
        ["--git-dir=" + clone + "/.git", "--work-tree=" + clone, "--no-replace-objects",
         "-c", "safe.bareRepository=explicit", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
         "-c", "diff.ignoreSubmodules=all", "-c", "advice.graftFileDeprecated=false"]
    }

    @discardableResult
    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        try inner.run(flags + args, in: dir, timeout: timeout, environment: environment.merging(["GIT_GRAFT_FILE": "/dev/null"]) { $1 })
    }
}
