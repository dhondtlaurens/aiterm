import Foundation
import Synchronization

/// One serial lane per repository, for git work that changes it: a checkout made or removed, a branch
/// moved, deleted or merged into. Work on one repository runs one job at a time, so two changes to it
/// never interleave; work on another repository never waits for it. A job can hold its lane for minutes
/// (`GitRunner.checkoutTimeout`: a checkout's hooks, a merge's checks), which on one queue for every
/// project left an unrelated project's create or Remove waiting behind it.
///
/// A repository is known by its git common directory, which its own checkout and every one of its
/// worktrees share, so a task's worktree and its project's folder are one lane. The common directory is
/// read from disk (`.git`, and a linked worktree's `gitdir:` file and `commondir`), never asked of git:
/// finding the lane costs no process. A folder in no repository is a lane of its own.
///
/// Questions that change nothing — a head, whether a checkout has unsaved work — leave the lane and run
/// on the shared pool (`BackgroundWork`): they need not wait for a checkout another task is making.
public final class GitLanes: Sendable {
    /// The app's lanes: every owner of git work that changes a repository asks this one.
    public static let shared = GitLanes()

    private let lanes = Mutex<[String: DispatchQueue]>([:])

    public init() {}

    /// The lane for the repository `path` is in.
    public func lane(for path: String) -> DispatchQueue {
        let key = Self.repository(of: path)
        return lanes.withLock { lanes in
            if let lane = lanes[key] { return lane }
            let lane = DispatchQueue(label: "aiterm.git-lane", qos: .userInitiated)
            lanes[key] = lane
            return lane
        }
    }

    /// The git common directory of the repository `path` is in, canonical; `path` itself, canonical, when
    /// it is in none that can be read.
    static func repository(of path: String) -> String {
        var directory = CanonicalPath.of(path)
        while true {
            let dotGit = directory == "/" ? "/.git" : directory + "/.git"
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return CanonicalPath.of(dotGit) }
                return linkedCommonDirectory(dotGit, in: directory) ?? directory
            }
            guard directory != "/" else { return CanonicalPath.of(path) }
            directory = (directory as NSString).deletingLastPathComponent
        }
    }

    /// A linked worktree's `.git` file names its own git directory (`gitdir: …`), whose `commondir` names
    /// the repository's, relative to it.
    private static func linkedCommonDirectory(_ file: String, in directory: String) -> String? {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
        let gitDirectory = absolute(line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces), in: directory)
        guard let common = try? String(contentsOfFile: gitDirectory + "/commondir", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty else { return CanonicalPath.of(gitDirectory) }
        return CanonicalPath.of(absolute(common, in: gitDirectory))
    }

    private static func absolute(_ path: String, in directory: String) -> String {
        path.hasPrefix("/") ? path : directory + "/" + path
    }
}
