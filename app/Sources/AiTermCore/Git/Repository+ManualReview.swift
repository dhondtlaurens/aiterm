import Foundation

public struct ManualReviewInput: Sendable {
    public let workspace: URL
    public let target: String
    public let base: String
    public let empty: Bool
}

public extension Repository {
    /// Pin by branch ref, after verifying its attachment. Even a concurrent switch between
    /// these reads cannot substitute the commit of the newly checked-out branch.
    func manualReview(draft: ReviewDraft, checkout: String) throws -> ManualReview.Pending {
        let ref = "refs/heads/" + draft.branch
        guard try git.run(["symbolic-ref", "HEAD"], in: checkout) == ref,
              let head = try commit(ref) else { throw ManualReviewError("The checkout no longer owns " + draft.branch) }
        return try ManualReview(repository: path, branch: draft.branch, head: head, target: draft.mr?.targetBranch,
                                agent: draft.agent, model: draft.model, effort: draft.reasoning,
                                context: TaskWorkflow.prompt(of: draft)).stage()
    }

    func prepareManualReview(head: String, target requested: String?, in folder: URL) throws -> ManualReviewInput {
        let fm = FileManager.default
        let workspace = folder.appendingPathComponent("workspace"), source = workspace.appendingPathComponent("source")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let store = folder.appendingPathComponent("objects.git")
        let targetName = try requested ?? detectDefaultBranch()
        guard let targetName, try BranchNaming.isValid(targetName, git: git) else {
            throw ManualReviewError("Could not resolve a review target branch.")
        }
        let targetRef = "refs/heads/" + targetName
        let objectPath = try git.run(["rev-parse", "--path-format=absolute", "--git-path", "objects"], in: path)
        let format = try git.run(["rev-parse", "--show-object-format"], in: path)
        guard try git.run(["rev-parse", "--is-shallow-repository"], in: path) == "false" else {
            throw ManualReviewError("A complete history is needed to verify the review merge base.")
        }
        try git.run(["init", "--bare", "--template=", "--object-format=" + format, store.path], in: folder.path)
        let env = ["GIT_OBJECT_DIRECTORY": store.appendingPathComponent("objects").path,
                   "GIT_ALTERNATE_OBJECT_DIRECTORIES": objectPath]
        let isolated = env.merging(["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                                    "GIT_ATTR_NOSYSTEM": "1"]) { _, new in new }
        func privateGit(_ args: [String]) throws -> String {
            try git.run(args, in: store.path, timeout: GitRunner.checkoutTimeout, environment: isolated)
        }
        func fileList(_ flags: [String]) throws -> String {
            let output = try git.output(["ls-files"] + flags, in: store.path, timeout: GitRunner.checkoutTimeout,
                                        environment: isolated, limit: 128 << 20)
            guard !output.truncated else { throw ManualReviewError("The committed file list exceeds the capture limit.") }
            return output.text
        }
        let target: String
        if try hasOrigin {
            let listed: String
            do { listed = try git.runRemote(["ls-remote", "--exit-code", "origin", targetRef], in: path) }
            catch { throw ManualReviewError("Could not verify " + targetRef + " on origin. " + error.localizedDescription) }
            guard let line = listed.split(separator: "\n").first(where: { $0.hasSuffix("\t" + targetRef) }),
                  let id = line.split(separator: "\t").first else { throw ManualReviewError("Origin has no branch " + targetName) }
            target = String(id)
            if try commit(target) == nil {
                try git.run(GitRunner.stallGuard + ["fetch", "--no-write-fetch-head", "--refmap=", "--no-tags", "--no-prune",
                    "--no-recurse-submodules", "--no-auto-maintenance", "--no-write-commit-graph", "origin", targetRef],
                    in: path, timeout: GitRunner.remoteTimeout, environment: env)
            }
        } else {
            guard let local = try commit(targetRef) else { throw ManualReviewError("Missing review target " + targetName) }
            target = local
        }
        let base = try privateGit(["merge-base", target, head])
        let patch = workspace.appendingPathComponent("changes.patch")
        _ = try privateGit(["diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", "--no-color",
                            "--output=" + patch.path, base, head, "--"])
        // An isolated index materializes all tracked files, including export-ignore entries.
        // Disable checkout conversions and filters even if the source tree requests them.
        try fm.createDirectory(at: store.appendingPathComponent("info"), withIntermediateDirectories: true)
        try Data("* -text -crlf !eol -ident -filter !working-tree-encoding\n".utf8)
            .write(to: store.appendingPathComponent("info/attributes"))
        _ = try privateGit(["read-tree", head])
        _ = try privateGit(["--work-tree=" + source.path, "-c", "core.symlinks=false", "-c", "core.autocrlf=false",
                            "checkout-index", "--all", "--prefix=" + source.path + "/"])
        let paths = try fileList([])
        try Data(paths.utf8).write(to: workspace.appendingPathComponent("paths.txt"))
        let links = try fileList(["--stage", "-z"])
        for entry in links.split(separator: "\0") where entry.hasPrefix("160000 ") {
            let parts = entry.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { throw ManualReviewError("Invalid submodule entry.") }
            let id = parts[0].split(separator: " ")[1]
            try Data((id + "\n").utf8).write(to: source.appendingPathComponent(String(parts[1])).appendingPathComponent("gitlink"))
        }
        let size = try patch.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return ManualReviewInput(workspace: workspace, target: target, base: base, empty: size == 0)
    }
}
