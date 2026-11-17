import Foundation

/// What one read of a GitHub pull request says about merging it: the pull's own fields and the checks on the head
/// that same answer names.
public struct GitHubPullFacts: Equatable, Sendable {
    /// One check run (GitHub Actions and other apps).
    public struct CheckRun: Decodable, Equatable, Sendable { public var name: String, status: String, conclusion: String? }
    /// One commit status (the older API some CI still reports through).
    public struct CommitStatus: Decodable, Equatable, Sendable { public var context: String, state: String }

    public enum Checks: Equatable, Sendable {
        /// Both lists, each read to the end.
        case listed(runs: [CheckRun], statuses: [CommitStatus])
        /// A list could not be read whole, or the lists were not read because the pull is not open.
        case notListedWhole
    }

    public var state: String, merged: Bool, draft: Bool
    /// GitHub's `mergeable`: nil while it has not worked it out.
    public var mergeable: Bool?
    public var mergeableState: String?
    public var head: String, mergeCommit: String?, baseRef: String?
    public var checks: Checks

    /// A head's checks as merging reads them, one table for the readiness and the pipeline word alike: GitHub's own,
    /// where neutral and skipped pass as branch protection counts them. Stale, which only GitHub sets on a run that took
    /// too long, never finishes, so it has failed. A failed check is said before one still running, and a conclusion
    /// AiTerm does not know, or none on a completed run, is not green.
    enum CheckSummary { case failed(String), running, green }

    static func checkSummary(runs: [CheckRun], statuses: [CommitStatus]) -> CheckSummary {
        var running = false
        for run in runs {
            guard run.status == "completed" else { running = true; continue }
            switch run.conclusion ?? "" {
            case "success", "neutral", "skipped": continue
            case "failure", "timed_out", "startup_failure": return .failed("its check \(run.name) failed")
            case "cancelled": return .failed("its check \(run.name) was cancelled")
            case "action_required": return .failed("its check \(run.name) needs someone to act")
            case "stale": return .failed("its check \(run.name) went stale")
            default: running = true
            }
        }
        for status in statuses {
            switch status.state {
            case "success": continue
            case "failure", "error": return .failed("its status \(status.context) failed")
            default: running = true
            }
        }
        return running ? .running : .green
    }
}

public extension GitHubPullFacts.Checks {
    /// The checks as one word, `failure`, `pending` or `success`; nil when they were not listed whole or there are
    /// none at all, so a head with no checks is never green.
    var pipeline: String? {
        guard case .listed(let runs, let statuses) = self, !runs.isEmpty || !statuses.isEmpty else { return nil }
        switch GitHubPullFacts.checkSummary(runs: runs, statuses: statuses) {
        case .failed: return "failure"
        case .running: return "pending"
        case .green: return "success"
        }
    }
}

public extension MergeReadiness {
    /// Whether GitHub would merge it now (a head with no check runs or statuses at all follows `mergeable_state`
    /// alone, so a caller debounces a ready answer): merged or closed first, then every check run and commit status on
    /// its head (`checkSummary`), then a draft (a merge waits for green whatever branch protection requires, and a
    /// pending check is not green yet), then `mergeable` and `mergeable_state`. Only `clean` and `has_hooks` with
    /// `mergeable` true is ready.
    static func gitHub(_ pull: GitHubPullFacts) -> MergeReadiness {
        if pull.merged { return .merged(commit: pull.mergeCommit ?? pull.head, head: pull.head, target: pull.baseRef) }
        guard pull.state == "open" else { return .blocked("the pull request is closed") }
        guard case .listed(let runs, let statuses) = pull.checks else { return .waiting("GitHub has not listed all its checks") }
        switch GitHubPullFacts.checkSummary(runs: runs, statuses: statuses) {
        case .failed(let why): return .blocked(why)
        case .running: return .waiting("its checks are running")
        case .green: break
        }
        // A draft is said once its checks and its conflicts have: what else stops it comes first.
        if pull.draft { return pull.mergeable == false ? .blocked("it has conflicts") : .blocked(draftReason) }
        switch pull.mergeableState ?? "unknown" {
        case "clean", "has_hooks": return pull.mergeable == true ? .ready(head: pull.head) : .waiting("GitHub is checking it")
        case "dirty": return .blocked("it has conflicts")
        case "behind": return .blocked("it is behind its base branch")
        case "blocked": return .waiting("it needs a review or a required check")
        case "draft": return .blocked(draftReason)
        // GitHub says a check does not pass that every list read here shows green: not ready until it agrees.
        case "unstable": return .waiting("GitHub says its checks are not all passing")
        default: return .waiting("GitHub is checking it")
        }
    }
}
