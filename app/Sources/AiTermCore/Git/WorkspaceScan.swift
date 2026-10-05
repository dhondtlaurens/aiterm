import Foundation

/// What one pass of the checkout monitor reads off disk. Blocking — every miss in the resolvers
/// runs git — so it is run off the main actor; the controller applies the result.
public struct WorkspaceScan: Equatable, Sendable {
    /// What a project's checkout says about the remote it pushes to.
    public struct Remote: Equatable, Sendable {
        public var provider: Provider, url: String?
        public init(provider: Provider, url: String?) { self.provider = provider; self.url = url }
    }

    /// Every directory a tab is in, mapped to the branch checked out there.
    public var branchByCwd: [String: String]
    /// Each project's own checkout, for rows whose window is closed and have no tab to read.
    public var projectBranch: [UUID: String]
    /// Tasks whose worktree is not on disk right now.
    public var missingCheckouts: Set<UUID>
    /// The missing ones whose removal is certain (see ``checkoutRemovalIsConfirmed(_:projectPath:)``).
    public var removedTasks: [TaskItem]
    /// Only projects whose checkout could be read and git asked: an unmounted or mid-move folder,
    /// or a git that timed out under load, says nothing about its provider, and silently clearing
    /// its remote would take the badge and its links.
    public var remotes: [UUID: Remote]
    /// Each task's checkout against its base branch, for the VS Code badge. Tasks whose worktree is
    /// missing, or whose base cannot be found, are absent.
    public var diffByTask: [UUID: DiffStat] = [:]
    /// Each project's default branch, for the menu's "Pull main". A folder that is not a checkout
    /// has none, and neither does one git could not be asked about while nothing was known of it.
    public var defaultBranch: [UUID: String] = [:]

    /// A scan's findings as given, for a stand-in scanner: the snapshot renderer's fixtures.
    public init(branchByCwd: [String: String], projectBranch: [UUID: String], missingCheckouts: Set<UUID>,
                removedTasks: [TaskItem], remotes: [UUID: Remote], diffByTask: [UUID: DiffStat] = [:],
                defaultBranch: [UUID: String] = [:]) {
        self.branchByCwd = branchByCwd; self.projectBranch = projectBranch; self.missingCheckouts = missingCheckouts
        self.removedTasks = removedTasks; self.remotes = remotes; self.diffByTask = diffByTask
        self.defaultBranch = defaultBranch
    }

    public static func run(cwds: [String], projects: [Project], tasks: [TaskItem],
                           branches: BranchResolver, remotes: RemoteResolver,
                           diffs: DiffStatResolver, defaultBranches: DefaultBranchResolver) -> WorkspaceScan {
        // The resolvers keep what they learn per directory; a directory no tab or project is in any
        // more — a worktree removed, a tab that wandered off — is forgotten rather than kept for good.
        let projectDirectories = Set(projects.map(\.path))
        branches.retain(only: projectDirectories.union(cwds))
        remotes.retain(only: projectDirectories)
        defaultBranches.retain(only: projectDirectories)
        let missing = Set(tasks.filter { !FileManager.default.fileExists(atPath: $0.worktreePath) }.map(\.id))
        let projectPaths = Dictionary(projects.map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first })
        var projectBranch: [UUID: String] = [:], found: [UUID: Remote] = [:], defaultBranch: [UUID: String] = [:]
        for project in projects {
            projectBranch[project.id] = branches.branch(for: project.path)
            defaultBranch[project.id] = defaultBranches.defaultBranch(for: project.path)
            if case .remote(let url) = remotes.remote(for: project.path) {
                found[project.id] = Remote(provider: ProviderDetector.detect(remoteUrl: url, repoPath: project.path).provider, url: url)
            }
        }
        return WorkspaceScan(
            branchByCwd: branches.branches(for: cwds), projectBranch: projectBranch, missingCheckouts: missing,
            removedTasks: tasks.filter { missing.contains($0.id) && checkoutRemovalIsConfirmed($0, projectPath: projectPaths[$0.projectId]) },
            remotes: found,
            diffByTask: diffs.diffs(for: tasks, skipping: missing), defaultBranch: defaultBranch)
    }

    /// Decides which session-list changes are worth a pass. The scan reads each tab's directory;
    /// the tab titles it produces read the tab's id, its row (`taskId`, `projectId`) and where it
    /// sits (`windowId`, `tabIndex`). Everything else a session event carries — a context fill, a
    /// state, a model, a title — changes nothing a pass would find, and arrives several times a
    /// second; the checkout monitor's own pass still catches what the tabs cannot announce.
    public struct SessionGate: Sendable {
        private struct Tab: Equatable, Sendable {
            let sessionId: String, cwd: String, windowId: String, tabIndex: Int, taskId: String?, projectId: String?
        }
        private var admitted: [Tab]?

        public init() {}

        /// Whether `sessions` differ from the last ones admitted in anything a pass reads; if so,
        /// they become the ones admitted.
        public mutating func admits(_ sessions: [SessionInfo]) -> Bool {
            let tabs = sessions.map {
                Tab(sessionId: $0.sessionId, cwd: $0.effectiveCwd, windowId: $0.windowId, tabIndex: $0.tabIndex,
                    taskId: $0.taskId, projectId: $0.projectId)
            }
            guard tabs != admitted else { return false }
            admitted = tabs
            return true
        }
    }

    /// Whether a task's worktree is gone for good, rather than out of reach. Missing mounts, missing
    /// parents and permission errors are not deletion evidence; only "no such file" inside a readable
    /// project and parent directory is.
    public static func checkoutRemovalIsConfirmed(_ task: TaskItem, projectPath: String?) -> Bool {
        guard let projectPath else { return false }
        let parent = URL(fileURLWithPath: task.worktreePath).deletingLastPathComponent().path
        for path in [projectPath, parent] {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  FileManager.default.isReadableFile(atPath: path) else { return false }
        }
        do {
            _ = try FileManager.default.attributesOfItem(atPath: task.worktreePath)
            return false
        } catch {
            let error = error as NSError
            return error.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
        }
    }
}
