import AiTermCore

// How the app words what git work on a project's branches and worktrees came to. Core reports each
// outcome as a value; the toasts and the banner say it here. A count git could not make is said
// without a number.

extension DefaultBranchPull {
    /// The toast that says it.
    var toast: String {
        switch self {
        case .upToDate(let branch): "\(branch) is already up to date."
        case .fastForwarded(let branch, let count?): "\(branch) updated with \(commits(count, adjective: "new"))."
        case .fastForwarded(let branch, nil): "\(branch) updated with origin’s new commits."
        case .ahead(let branch, let count?): "\(branch) is \(commits(count)) ahead of origin, so there was nothing to pull."
        case .ahead(let branch, nil): "\(branch) is ahead of origin, so there was nothing to pull."
        }
    }
}

extension BranchRebase {
    /// The toast that says it. Never pushed: that stays the person's to do.
    var toast: String {
        switch ahead {
        case 0: "\(branch) rebased onto origin: it now matches origin."
        case let ahead?: "\(branch) rebased onto origin: \(commits(ahead)) ahead, not pushed."
        case nil: "\(branch) rebased onto origin, not pushed."
        }
    }
}

extension ReviewBranchRelease.Kept {
    /// What a removed review's toast adds about its local `branch`: "Branch feat/x kept: 1 commit
    /// not on origin."
    func note(branch: String) -> String { "Branch \(branch) kept: \(reason(branch: branch))." }

    private func reason(branch: String) -> String {
        switch self {
        case .checkedOut(let path): "checked out at \(path)"
        case .originUnreachable(let why): "couldn’t check origin (\(why))"
        case .originNotFetched: "couldn’t fetch origin’s \(branch) to compare"
        case .unpushed(let count?): "\(commits(count)) not on origin"
        case .unpushed(nil): "commits not on origin"
        case .unmerged(let target): "not on origin and not merged into \(target.isEmpty ? "its target" : target)"
        case .notDeleted(let why): why
        case .unchecked(let why): "couldn’t check where its commits are (\(why))"
        }
    }
}

/// "1 commit", "3 new commits": a count of commits, as the toasts above say it.
private func commits(_ count: Int, adjective: String? = nil) -> String {
    ([String(count)] + [adjective].compactMap { $0 } + [count == 1 ? "commit" : "commits"]).joined(separator: " ")
}

extension WorktreeInclude.Outcome {
    /// The banner after a create whose `.worktreeinclude` copy left something out; `nil` when
    /// nothing was. The task was created either way.
    var bannerMessage: String? {
        switch self {
        case .complete: nil
        case .unread: "Couldn’t read what .worktreeinclude lists, so no files were copied into the new worktree."
        case .notCopied(let files): "Couldn’t copy \(named(files)) into the new worktree."
        }
    }
}

/// ".env", ".env and certs/dev.pem", "a, b and c", "a, b, c and 2 more files": files named in a message.
private func named(_ files: [String]) -> String {
    let shown = Array(files.prefix(3)), more = files.count - shown.count
    if more > 0 { return shown.joined(separator: ", ") + " and \(more) more \(more == 1 ? "file" : "files")" }
    guard let last = shown.last, shown.count > 1 else { return shown.first ?? "" }
    return shown.dropLast().joined(separator: ", ") + " and " + last
}
