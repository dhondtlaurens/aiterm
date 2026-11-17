import Foundation

/// The fields of a GitLab merge request that say whether it can merge now, from a read of it or from the answer to a
/// merge. Decoded with snake-case keys converted, as every host answer is.
public struct GitLabMergeFacts: Decodable, Equatable, Sendable {
    public struct Pipeline: Decodable, Equatable, Sendable { public var status: String? }
    public var state: String?, detailedMergeStatus: String?, sha: String?, draft: Bool?, hasConflicts: Bool?
    public var targetBranch: String?
    public var mergeCommitSha: String?, squashCommitSha: String?, headPipeline: Pipeline?
}

public extension MergeReadiness {
    /// Whether GitLab would merge it now: its pipeline first (a merge waits for green whatever the project requires),
    /// then whether it is a draft, then GitLab's `detailed_merge_status`.
    static func gitLab(_ request: GitLabMergeFacts) -> MergeReadiness {
        let sha = request.sha, draft = request.draft
        if request.state == "merged" {
            return .merged(commit: request.mergeCommitSha ?? request.squashCommitSha ?? sha ?? "", head: sha ?? "", target: request.targetBranch)
        }
        guard request.state == "opened" else { return .blocked("the merge request is \(request.state ?? "not open")") }
        switch request.headPipeline?.status ?? "" {
        case "failed": return .blocked("its pipeline failed")
        case "canceled": return .blocked("its pipeline was canceled")
        case "created", "waiting_for_resource", "preparing", "waiting_for_callback", "pending", "running", "scheduled", "canceling":
            return .waiting("its pipeline is running")
        // A pipeline that stopped at a manual job or never ran has not passed, whatever the project requires.
        case "manual": return .blocked("the pipeline waits for a manual job")
        // Many CIs skip the pipeline while it is a draft: no failure then, so the draft is all that stops it.
        case "skipped" where draft == true: break
        case "skipped": return .blocked("the pipeline was skipped")
        case "", "success": break   // green, or no pipeline at all
        case let other: return .waiting("its pipeline is \(other.replacingOccurrences(of: "_", with: " "))")
        }
        // A draft is said once its pipeline has: what else stops it comes first.
        if draft == true { return request.hasConflicts == true ? .blocked("it has conflicts") : .blocked(draftReason) }
        guard let status = request.detailedMergeStatus else { return .waiting("GitLab is checking it") }
        switch status {
        case "mergeable": return sha.map { .ready(head: $0) } ?? .waiting("GitLab is checking it")
        case "checking", "unchecked", "preparing", "approvals_syncing", "ci_still_running": return .waiting("GitLab is checking it")
        case "ci_must_pass": return .waiting("its pipeline must pass")
        case "not_approved": return .waiting("it needs an approval")
        case "conflict": return .blocked("it has conflicts")
        case "need_rebase": return .blocked("it needs a rebase")
        case "draft_status": return .blocked(draftReason)
        case "discussions_not_resolved": return .blocked("it has unresolved threads")
        default: return .blocked("GitLab says " + status.replacingOccurrences(of: "_", with: " "))
        }
    }
}
