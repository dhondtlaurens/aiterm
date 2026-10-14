import Foundation

/// Every way a fix stops short of landing, as the sentence the footer or banner shows. A refusal
/// leaves the real repository as it was.
public enum FixRefusal: Error, Equatable, LocalizedError {
    case unreadableAnswer(FixerAgent)
    case agentFailed(FixerAgent, summary: String)
    case agentExited(FixerAgent, status: Int32, stderr: String)
    case timedOut(FixerAgent)
    case operationInProgress
    case conflictMarkers([String])
    case uncommittedChanges
    case movedOtherBranch(String)
    case droppedCommit(String, sha: String)
    case tooManyCommits(String, count: Int)
    case verifyFailed(String, status: Int32)
    case branchMovedMeanwhile(String)
    case checkoutHasChanges(String)
    case cloneFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableAnswer(let a):
            "\(a.shortName)’s answer was not a plan AiTerm can check."
        case .agentFailed(let a, let summary):
            "\(a.shortName) couldn’t finish its fix: \(summary)"
        case .agentExited(let a, let status, let stderr):
            "\(a.shortName) stopped with status \(status)\(stderr.isEmpty ? "." : ": " + GitError.firstLine(stderr))"
        case .timedOut(let a):
            "\(a.shortName) ran out of time, so nothing was changed."
        case .operationInProgress:
            "The fix left a rebase or merge unfinished, so nothing was changed."
        case .conflictMarkers(let files):
            "The fix left conflict markers in \(files.prefix(3).joined(separator: ", "))\(files.count > 3 ? " and \(files.count - 3) more" : ""), so nothing was changed."
        case .uncommittedChanges:
            "The fix left changes it didn’t commit, so nothing was changed."
        case .movedOtherBranch(let b):
            "The fix moved “\(b)”, which it wasn’t allowed to, so nothing was changed."
        case .droppedCommit(let b, let sha):
            "The fix would have dropped commit \(sha.prefix(7)) from “\(b)” without saying so, so nothing was changed."
        case .tooManyCommits(let b, let count):
            "“\(b)” has \(count) commits that aren’t on origin — too many to check a fix against."
        case .verifyFailed(let command, let status):
            "\(command) failed (status \(status)) after the fix, so nothing was changed."
        case .branchMovedMeanwhile(let b):
            "“\(b)” moved while the fix was being made, so nothing was changed. Try again."
        case .checkoutHasChanges(let path):
            "\(URL(fileURLWithPath: path).lastPathComponent) has uncommitted changes, so the fix wasn’t brought in. Commit or stash them, then try again."
        case .cloneFailed(let reason):
            "Couldn’t prepare a copy of the repository: \(reason)"
        }
    }
}
