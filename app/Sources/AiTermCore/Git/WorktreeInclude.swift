import Foundation

/// A project's `.worktreeinclude`: the gitignored files a new worktree should start with — `.env`,
/// local certificates — which a checkout of tracked files never has. It is the convention Claude
/// Code, Conductor and PostHog Desktop read: a file at the repository's root in `.gitignore`'s
/// syntax, selecting only files git ignores and the project's checkout has. It never makes a file
/// tracked. There is no setting: the file is the setting, and step 1's checkbox the one-off
/// exception.
public enum WorktreeInclude {
    public static let fileName = ".worktreeinclude"

    /// What copying the selected files into a new worktree came to. A value: the app words it.
    public enum Outcome: Equatable, Sendable {
        /// Everything selected is in the worktree — copied, or there already — or nothing was asked for.
        case complete
        /// git could not say what the file selects, so nothing was copied.
        case unread
        /// These, relative to the checkout, were not copied; everything else was.
        case notCopied([String])
    }

    /// The files `.worktreeinclude` selects in `repository`'s checkout, relative to it: untracked
    /// files its patterns match that git's own rules — `.gitignore`, `info/exclude`, the global
    /// excludes — also ignore. Empty, without asking git, when the project has no such file. Thrown
    /// when git could not be asked, which says nothing about what it selects.
    ///
    /// Two listings. The first walks every untracked folder, ignored ones included, because a
    /// pattern like `.env` matches at any depth; the second, `git status`'s untracked files, skips
    /// ignored folders like `node_modules`, so it stays small. What the first has and the second
    /// lacks is ignored. Another worktree is never a source: git does not enter a live one, and a
    /// folder a removal left under `.worktrees/` is skipped by name. A nested repository is listed
    /// as a folder, which is not copied.
    public static func matches(in repository: Repository) throws -> [String] {
        let list = repository.path + "/" + fileName
        guard FileManager.default.fileExists(atPath: list) else { return [] }
        let selected = paths(try repository.git.run(["ls-files", "-z", "--others", "--ignored", "--exclude-from=" + list],
                                                    in: repository.path))
            .filter { !$0.hasSuffix("/") && !$0.hasPrefix(Worktree.directoryName + "/") }
        guard !selected.isEmpty else { return [] }
        let unignored = Set(paths(try repository.git.run(["ls-files", "-z", "--others", "--exclude-standard"], in: repository.path)))
        return selected.filter { !unignored.contains($0) }
    }

    /// ``matches(in:)``, copied from `repository`'s checkout into `worktree`. Every failure is
    /// logged and comes back as a value: the worktree exists by now, and a create never fails over
    /// a file.
    public static func copy(from repository: Repository, into worktree: String) -> Outcome {
        let files = Log.git.attempt("Listing what \(fileName) selects in \(repository.path)") { try matches(in: repository) }
        guard let files else { return .unread }
        return copy(files, from: repository.path, into: worktree)
    }

    /// Each of `files` copied from `checkout` to the same path in `worktree`, its folders made as
    /// needed: `FileManager.copyItem`, which clones on APFS, so a copy costs no space until either
    /// side changes. Whatever the worktree already has at a path — a file its branch tracks, one a
    /// checkout hook wrote, a symlink to nothing — is its own and left alone. Never through a
    /// symlinked folder: a branch can track `certs` as a link out of the worktree.
    static func copy(_ files: [String], from checkout: String, into worktree: String) -> Outcome {
        var failed: [String] = []
        for file in files where !exists(worktree + "/" + file) {
            do {
                let folder = (file as NSString).deletingLastPathComponent
                if let link = firstSymlink(on: folder, in: worktree) { throw ThroughSymlink(path: link) }
                if !folder.isEmpty {
                    try FileManager.default.createDirectory(atPath: worktree + "/" + folder, withIntermediateDirectories: true)
                }
                try FileManager.default.copyItem(atPath: checkout + "/" + file, toPath: worktree + "/" + file)
            } catch {
                Log.git.failed("Copying \(file) from \(fileName) into \(worktree)", error)
                failed.append(file)
            }
        }
        return failed.isEmpty ? .complete : .notCopied(failed)
    }

    /// A folder on a file's way into the worktree that is a symlink, for the log.
    private struct ThroughSymlink: Error, CustomStringConvertible {
        let path: String
        var description: String { "\(path) is a symlink" }
    }

    /// Whether anything is at `path`, a symlink — dangling or not — included: `attributesOfItem`
    /// does not follow a last symlink, where `fileExists` does.
    private static func exists(_ path: String) -> Bool { (try? FileManager.default.attributesOfItem(atPath: path)) != nil }

    /// The first folder on `folder`'s way down from `root` that is a symlink; `nil` when none is,
    /// folders not made yet included.
    private static func firstSymlink(on folder: String, in root: String) -> String? {
        var path = root
        for component in folder.split(separator: "/") {
            path += "/" + component
            guard let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else { return nil }
            if type == .typeSymbolicLink { return path }
        }
        return nil
    }

    /// A `-z` listing's paths. Unquoted, so a space or an accent comes through as it is.
    private static func paths(_ listing: String) -> [String] { listing.split(separator: "\0").map(String.init) }
}
