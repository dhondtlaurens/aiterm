import Foundation

/// A task base that names the current branch before its first commit. The sheet can offer
/// initialization; other callers still get an actionable explanation without promising a button.
public struct UnbornBranchError: Error, Equatable, LocalizedError {
    public let branch: String
    public init(branch: String) { self.branch = branch }
    public var errorDescription: String? {
        "“\(branch)” has no commits. Create an empty first commit to start a task. Existing files stay uncommitted in the project folder."
    }
}

public enum RepositoryInitializationError: Error, Equatable, LocalizedError {
    case headChanged
    case commitFailed(branch: String, cause: GitError)

    public var errorDescription: String? {
        switch self {
        case .headChanged:
            return "The project’s checked-out branch changed. Retry task creation to check the base again."
        case .commitFailed(_, let cause):
            let words = cause.stderr.lowercased()
            if ["identity unknown", "auto-detect email", "empty ident", "no email was given", "no name was given"].contains(where: words.contains) {
                return "Git needs your name and email. In the project folder, run git config user.name \"Your name\" and git config user.email \"you@example.com\", then retry."
            }
            return "Couldn’t create the empty first commit. " + GitError.sentence(of: cause)
        }
    }
}

extension Repository {
    /// Git's symbolic HEAD when it has no commit. A detached HEAD or an unreadable repository
    /// is never guessed to be unborn. Uses Git rather than its on-disk ref format.
    func unbornBranch() throws -> String? {
        guard let head = try git.ask(["symbolic-ref", "--quiet", "HEAD"], in: path, none: [1]),
              head.hasPrefix("refs/heads/"), try commit("HEAD") == nil else { return nil }
        return String(head.dropFirst("refs/heads/".count))
    }

    /// Only after explicit consent to an empty first commit on `branch`. A repository initialized
    /// elsewhere meanwhile needs no further commit; a changed checkout needs a fresh decision.
    public func initializeEmptyRepository(on branch: String) throws {
        guard try git.ask(["symbolic-ref", "--quiet", "HEAD"], in: path, none: [1]) == "refs/heads/" + branch else {
            throw RepositoryInitializationError.headChanged
        }
        guard try commit("HEAD") == nil else { return }
        do {
            // --only with no paths excludes the real index, including staged files. Disable hooks
            // for this empty commit so a global hook cannot stage files or rewrite the checkout.
            // Require a configured identity instead of letting Git guess the person's email.
            try git.run(["-c", "core.hooksPath=/dev/null", "-c", "user.useConfigOnly=true",
                         "commit", "--only", "--allow-empty", "-m", "Initial commit"], in: path,
                        timeout: GitRunner.checkoutTimeout)
        } catch let cause as GitError {
            throw RepositoryInitializationError.commitFailed(branch: branch, cause: cause)
        }
    }
}
