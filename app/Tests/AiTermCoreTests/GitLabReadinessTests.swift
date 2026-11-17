import Testing
@testable import AiTermCore

/// GitLab's merge readiness, decided from the fields of one read of a merge request: no network.
@Suite struct GitLabReadinessTests {
    static let head = "4f2a91c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6"
    static let mergeCommit = "9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d"

    /// A merge request as GitLab describes it in each state AiTerm reads.
    static func request(state: String = "opened", detailed: String, pipeline: String?, draft: Bool = false,
                        conflicts: Bool? = nil) -> GitLabMergeFacts {
        GitLabMergeFacts(state: state, detailedMergeStatus: detailed, sha: head, draft: draft, hasConflicts: conflicts ?? (detailed == "conflict"),
                         targetBranch: "main", mergeCommitSha: state == "merged" ? mergeCommit : nil, squashCommitSha: nil,
                         headPipeline: pipeline.map { GitLabMergeFacts.Pipeline(status: $0) })
    }

    @Test func readinessFollowsItsPipelineThenGitLabsMergeStatus() {
        let cases: [(state: String, pipeline: String?, detailed: String, expected: MergeReadiness)] = [
            ("opened", "running", "ci_still_running", .waiting("its pipeline is running")),
            ("opened", "pending", "mergeable", .waiting("its pipeline is running")),
            ("opened", "failed", "ci_must_pass", .blocked("its pipeline failed")),
            ("opened", "canceled", "mergeable", .blocked("its pipeline was canceled")),
            ("opened", "success", "mergeable", .ready(head: Self.head)),
            ("opened", nil, "mergeable", .ready(head: Self.head)),
            ("opened", "success", "not_approved", .waiting("it needs an approval")),
            ("opened", "success", "checking", .waiting("GitLab is checking it")),
            ("opened", "success", "conflict", .blocked("it has conflicts")),
            ("opened", "success", "need_rebase", .blocked("it needs a rebase")),
            ("opened", "success", "discussions_not_resolved", .blocked("it has unresolved threads")),
            ("opened", "success", "jira_association_missing", .blocked("GitLab says jira association missing")),
            ("merged", "success", "not_open", .merged(commit: Self.mergeCommit, head: Self.head, target: "main")),
            ("closed", nil, "not_open", .blocked("the merge request is closed")),
        ]
        for item in cases {
            #expect(MergeReadiness.gitLab(Self.request(state: item.state, detailed: item.detailed, pipeline: item.pipeline)) == item.expected,
                    "\(item.state) \(item.pipeline ?? "no pipeline") \(item.detailed)")
        }
    }

    @Test func aDraftIsNeverReady() {
        #expect(MergeReadiness.gitLab(Self.request(detailed: "mergeable", pipeline: "success", draft: true)) == .blocked("it is a draft"))
    }

    /// Many CIs skip the pipeline of a draft: skipped is no failure while it is one, so the draft is all that stops it and
    /// it is marked ready. Not a draft, a skipped pipeline still blocks; a draft with conflicts says so.
    @Test func aDraftsSkippedPipelineLeavesTheDraftAsItsOnlyBlocker() {
        #expect(MergeReadiness.gitLab(Self.request(detailed: "draft_status", pipeline: "skipped", draft: true)) == .blocked("it is a draft"))
        #expect(MergeReadiness.gitLab(Self.request(detailed: "mergeable", pipeline: "skipped")) == .blocked("the pipeline was skipped"))
        #expect(MergeReadiness.gitLab(Self.request(detailed: "draft_status", pipeline: "skipped", draft: true, conflicts: true))
                == .blocked("it has conflicts"))
    }

    /// A draft's pipeline is read first: what else stops it is said before the draft.
    @Test func aDraftsPipelineIsSaidBeforeTheDraft() {
        #expect(MergeReadiness.gitLab(Self.request(detailed: "draft_status", pipeline: "failed", draft: true)) == .blocked("its pipeline failed"))
    }

    @Test func anUnknownPipelineStatusIsNotGreen() {
        #expect(MergeReadiness.gitLab(Self.request(detailed: "mergeable", pipeline: "on_hold")) == .waiting("its pipeline is on hold"))
    }

    @Test func aPipelineThatDidNotRunIsNotGreen() {
        let cases: [(pipeline: String, expected: MergeReadiness)] = [
            ("manual", .blocked("the pipeline waits for a manual job")),
            ("skipped", .blocked("the pipeline was skipped")),
        ]
        for item in cases {
            #expect(MergeReadiness.gitLab(Self.request(detailed: "mergeable", pipeline: item.pipeline)) == item.expected, "\(item.pipeline)")
        }
    }
}
