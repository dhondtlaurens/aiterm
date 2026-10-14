import Foundation

/// A fix's result as it landed: the branch, where it was, where it is, and the backup's name.
public struct FixLanding: Equatable, Sendable {
    public var branch: String, old: String, new: String
    /// The old tip's name for a person: `refs/aiterm/backup/<branch>`, not under `refs/heads`, so no
    /// branch picker lists it.
    public var backup: String { "aiterm/backup/" + branch }
}

extension Repository {
    /// Brings a checked fix from its clone into this repository — AiTerm's own git, no agent. The
    /// new commits are fetched under `refs/aiterm/fix/`, the old tip is kept as
    /// `refs/aiterm/backup/<branch>`, then the branch moves only if it is still where the clone
    /// started: `update-ref <new> <old>` where it is checked out nowhere, a fast-forward or
    /// `reset --keep` in its clean checkout otherwise. Every command runs with hooks off: what the
    /// fix changed in a hook must never run unsandboxed as it lands. A branch in the middle of a
    /// rebase, merge or bisect is refused, and so is a fix that would overwrite a file git ignores;
    /// untracked and ignored files are never touched. A refusal leaves the branch, the checkout and
    /// any earlier backup as they were.
    ///
    /// Internal: run it on `TaskWorkflow`'s queue (`TaskWorkflow.landFix`), the only public way in.
    func landFix(from clone: FixClone) throws(FixRefusal) -> FixLanding {
        let branch = clone.branch, old = clone.startTip, ref = "refs/heads/" + branch
        let temporary = "refs/aiterm/fix/" + branch, backup = "refs/aiterm/backup/" + branch
        do {
            // Before the fetch: a fetch killed after it wrote the ref must leak nothing.
            defer { _ = try? write(["update-ref", "-d", temporary]) }
            try write(["fetch", "-q", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules", clone.path,
                       "+\(ref):\(temporary)"], timeout: GitRunner.checkoutTimeout)
            let new = try git.run(["rev-parse", "--verify", temporary + "^{commit}"], in: path)
            guard try commit(ref) == old else { throw FixRefusal.branchMovedMeanwhile(branch) }

            // Everything that can refuse comes before the first write.
            let trees = try worktrees()
            try refuseIfInOperation(branch, in: trees)
            let holder = trees.first { $0.branch == branch }
            if let holder {
                guard try git.run(["status", "--porcelain", "--untracked-files=no"], in: holder.path).isEmpty else {
                    throw FixRefusal.checkoutHasChanges(holder.path)
                }
                guard try git.run(["rev-parse", "HEAD"], in: holder.path) == old else { throw FixRefusal.branchMovedMeanwhile(branch) }
                if try FixGuard.operationInProgress(in: holder.path, git: git) { throw FixRefusal.branchInOperation(branch) }
                let ignored = try ignoredFiles(changedFrom: old, to: new, in: holder.path)
                if !ignored.isEmpty { throw FixRefusal.wouldOverwriteIgnored(ignored) }
            }

            let earlierBackup = try commit(backup)
            func restoreBackup() {
                if let earlierBackup { _ = try? write(["update-ref", backup, earlierBackup]) }
                else { _ = try? write(["update-ref", "-d", backup]) }
            }
            do { try write(["update-ref", backup, old]) }
            catch {
                // A timeout may have come after git wrote the ref: put back what was there.
                restoreBackup()
                throw error
            }
            do {
                if let holder {
                    if try isAncestor(old, of: new) {
                        try write(["merge", "--ff-only", "--no-autostash", "--no-overwrite-ignore", "-q", new],
                                  in: holder.path, timeout: GitRunner.checkoutTimeout)
                    } else {
                        try write(["reset", "-q", "--keep", new], in: holder.path, timeout: GitRunner.checkoutTimeout)
                    }
                } else {
                    // Compare-and-swap: git moves the ref only if it still holds `old`.
                    try write(["update-ref", ref, new, old])
                }
            } catch {
                // Whatever failed — a timeout included — the branch says where things stand.
                // If it cannot be read, nobody knows what ran: the backup of the old tip stays.
                guard case .success(let tip) = Result(catching: { try commit(ref) }) else { throw error }
                if tip == new { return FixLanding(branch: branch, old: old, new: new) }
                if tip == old { restoreBackup(); throw error }
                // The branch is elsewhere. When git said no, the move was refused and nothing of ours
                // happened, so the earlier backup comes back.
                if let git = error as? GitError, !git.timedOut {
                    restoreBackup()
                    throw FixRefusal.branchMovedMeanwhile(branch)
                }
                // After a timeout nobody knows what ran, and the old tip stays safe under the backup.
                throw FixRefusal.landingFailed(branch, "git timed out and the branch has moved, so it was left alone. "
                                               + "Its old tip is kept as \(FixLanding(branch: branch, old: old, new: new).backup).")
            }
            return FixLanding(branch: branch, old: old, new: new)
        } catch let refusal as FixRefusal {
            throw refusal
        } catch {
            throw .landingFailed(branch, OperationIssue.reason(of: error))
        }
    }

    /// A git write in the real repository (or one of its checkouts), with hooks off.
    @discardableResult
    private func write(_ args: [String], in dir: String? = nil, timeout: TimeInterval = GitRunner.localTimeout) throws -> String {
        try git.run(["-c", "core.hooksPath=/dev/null"] + args, in: dir ?? path, timeout: timeout)
    }

    /// Refuses a branch some worktree is rebasing or bisecting: git lists such a worktree as
    /// detached, so only its git dir says which branch the operation is about.
    private func refuseIfInOperation(_ branch: String, in trees: [Worktree]) throws {
        for tree in trees where FileManager.default.fileExists(atPath: tree.path) {
            let gitDir = try git.run(["rev-parse", "--path-format=absolute", "--git-dir"], in: tree.path)
            func read(_ file: String) -> String? {
                (try? String(contentsOfFile: gitDir + "/" + file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if read("rebase-merge/head-name") == "refs/heads/" + branch
                || read("rebase-apply/head-name") == "refs/heads/" + branch
                || read("BISECT_START") == branch { throw FixRefusal.branchInOperation(branch) }
        }
    }

    /// The files the fix writes where `dir` has an untracked, ignored one — `reset --keep` and a
    /// merge would write over them, and nothing brings an ignored `.env` back. That is a file at a
    /// changed path, and a file at one of its leading directories (an ignored file `a` where the
    /// fix adds `a/b`). Only those exact paths are asked about, so an ignored directory beneath
    /// a changed one is not listed.
    private func ignoredFiles(changedFrom old: String, to new: String, in dir: String) throws -> [String] {
        // `--raw -z` lists `<meta> NUL <path> NUL` pairs. The runner trims what git prints, which
        // would cost a first path its leading spaces; here every path follows a NUL.
        let raw = try git.run(["diff", "--raw", "-z", "--no-renames", old, new], in: dir).split(separator: "\0").map(String.init)
        let changed = stride(from: 1, to: raw.count, by: 2).map { raw[$0] }
        var candidates = Set<String>(), seen = Set<String>()
        func exists(_ relative: String) -> FileAttributeType? {
            (try? FileManager.default.attributesOfItem(atPath: dir + "/" + relative))?[.type] as? FileAttributeType
        }
        for file in changed {
            if exists(file) != nil { candidates.insert(file) }
            var prefix = ""
            for part in file.split(separator: "/", omittingEmptySubsequences: false).dropLast() {
                prefix += (prefix.isEmpty ? "" : "/") + part
                if seen.insert(prefix).inserted, let type = exists(prefix), type != .typeDirectory { candidates.insert(prefix) }
            }
        }
        let ordered = candidates.sorted(), byTrimmed = Dictionary(ordered.map { ($0.trimmingCharacters(in: .whitespacesAndNewlines), $0) },
                                                                  uniquingKeysWith: { first, _ in first })
        var found: [String] = []
        for start in stride(from: 0, to: ordered.count, by: 200) {
            let chunk = Array(ordered[start..<min(start + 200, ordered.count)])
            let listed = try git.run(["--literal-pathspecs", "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--"] + chunk, in: dir)
            // The runner trimmed the first name; the candidates know it whole.
            found += listed.split(separator: "\0").map { byTrimmed[String($0).trimmingCharacters(in: .whitespacesAndNewlines)] ?? String($0) }
        }
        return found
    }
}
