import Foundation

/// A local publishing guard, not a sandbox. Launch environments and a pre-push hook use the same
/// rules; neither can authorize a push when its repository or the host's protection is unknown.
public enum WorkerGuard {
    public struct Scope: Codable, Equatable, Sendable {
        public var task: UUID
        public var worktree: String
        public var branch: String
        public var remote: String
        public var allowsPush: Bool
        public var ownership: Int = 0
        public var stage: Int?
        public init(task: UUID, worktree: String, branch: String, remote: String, allowsPush: Bool) {
            self.task = task; self.worktree = worktree; self.branch = branch; self.remote = remote; self.allowsPush = allowsPush
        }
    }
    public struct Push: Equatable, Sendable {
        public var localRef: String, localSHA: String, remoteRef: String, remoteSHA: String
    }
    public static func commandDenial(_ command: String, branch: String, allowsPush: Bool) -> String? {
        ShellGate.publishingDenial(command) { argvDenial(program: $0, arguments: $1, branch: branch, allowsPush: allowsPush) }
    }
    public static func pushes(_ input: String) throws -> [Push] {
        try input.split(whereSeparator: \.isNewline).map { line in
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.count == 4, CommitId.isFull(words[1]), CommitId.isFull(words[3]) else {
                throw GuardFailure("Git's pre-push ref list could not be read.")
            }
            return Push(localRef: words[0], localSHA: words[1], remoteRef: words[2], remoteSHA: words[3])
        }
    }
    public static func pushDenial(_ pushes: [Push], scope: Scope, remote: String, head: String, defaultBranch: String,
                                 protection: BranchProtection, isAncestor: (String, String) throws -> Bool) rethrows -> String? {
        guard scope.allowsPush else { return "Publishing is not enabled for this worker." }
        guard !scope.branch.isEmpty, !defaultBranch.isEmpty,
              Repository.folded(Repository.shortBranch(scope.branch)) != Repository.folded(Repository.shortBranch(defaultBranch)) else {
            return "Workers never push the default branch."
        }
        guard Repository.sameLocation(scope.remote, remote) else { return "This push goes to another repository." }
        if case .protected = protection { return "Workers never push a protected branch." }
        let ref = "refs/heads/" + Repository.shortBranch(scope.branch)
        for push in pushes {
            guard push.remoteRef == ref, push.localRef == ref || push.localRef == "HEAD" else { return "A worker may push only its own task branch." }
            guard push.localSHA.contains(where: { $0 != "0" }), push.localSHA == head else { return "A worker may push only its task branch's current commit, and may not delete a branch." }
            if push.remoteSHA.contains(where: { $0 != "0" }), try !isAncestor(push.remoteSHA, push.localSHA) {
                return "Workers never force-push or replace remote history."
            }
        }
        return nil
    }
    public struct GuardFailure: LocalizedError, Equatable, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
