import Foundation

/// A problem a surface hands to a fix: what the person saw, git's own words, and the one branch the
/// fix may move. Data only, so a test asserts on it and `@Observable` compares it.
public struct FixRequest: Equatable, Sendable {
    public var title: String
    public var reason: String?
    /// Git's whole output for the failure, when there was one: the agent reads it as data.
    public var detail: String?
    public var projectPath: String
    public var branch: String
    /// Whether the clone recreates the stopped rebase, so the agent sees the conflict itself.
    public var recreateRebase: Bool
    public var retry: FixRetry
    /// Why the last fix for this problem was refused, when the person tried again: the next Look is told.
    public var previousFailure: String?

    public init(title: String, reason: String?, detail: String?, projectPath: String, branch: String,
                recreateRebase: Bool, retry: FixRetry, previousFailure: String? = nil) {
        self.title = title; self.reason = reason; self.detail = detail; self.projectPath = projectPath
        self.branch = branch; self.recreateRebase = recreateRebase; self.retry = retry
        self.previousFailure = previousFailure
    }
}

/// What runs again once a fix has landed. Cases, not closures: the app maps each to its call.
public enum FixRetry: Equatable, Sendable {
    /// The New Review sheet's create, which its own model runs.
    case createReview
    /// “Pull main” of the project with this id.
    case pullDefault(UUID)
}
