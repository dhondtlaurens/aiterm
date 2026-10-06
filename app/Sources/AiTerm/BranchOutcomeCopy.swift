import AiTermCore

// How the app words what git work on a project's branches came to. Core reports each outcome as a
// value; the toasts say it here.

extension DefaultBranchPull {
    /// The toast that says it.
    var toast: String {
        switch self {
        case .upToDate(let branch): "\(branch) is already up to date."
        case .fastForwarded(let branch, let count): "\(branch) updated with \(commits(count, adjective: "new"))."
        case .ahead(let branch, let count): "\(branch) is \(commits(count)) ahead of origin, so there was nothing to pull."
        }
    }
}

extension DefaultBranchRebase {
    /// The toast that says it. Never pushed: that stays the person's to do.
    var toast: String {
        ahead == 0 ? "\(branch) rebased onto origin: it now matches origin."
            : "\(branch) rebased onto origin: \(commits(ahead)) ahead, not pushed."
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
        case .unpushed(let count): "\(commits(count)) not on origin"
        case .unmerged(let target): "not on origin and not merged into \(target.isEmpty ? "its target" : target)"
        case .notDeleted(let why): why
        }
    }
}

/// "1 commit", "3 new commits": a count of commits, as the toasts above say it.
private func commits(_ count: Int, adjective: String? = nil) -> String {
    ([String(count)] + [adjective].compactMap { $0 } + [count == 1 ? "commit" : "commits"]).joined(separator: " ")
}
