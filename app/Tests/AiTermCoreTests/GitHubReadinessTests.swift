import Testing
@testable import AiTermCore

/// GitHub's merge readiness and pipeline word, decided from the facts of one read of a pull: no network.
@Suite struct GitHubReadinessTests {
    static let head = "4f2a91c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6"
    static let mergeCommit = "9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d"
    typealias Run = GitHubPullFacts.CheckRun
    typealias Status = GitHubPullFacts.CommitStatus

    static func run(_ name: String, _ status: String, _ conclusion: String?) -> Run { Run(name: name, status: status, conclusion: conclusion) }
    static func status(_ context: String, _ state: String) -> Status { Status(context: context, state: state) }
    static let green = [run("test", "completed", "success")]

    static func pull(state: String = "open", draft: Bool = false, merged: Bool = false, mergeable: Bool? = true,
                     mergeableState: String = "clean", runs: [Run] = green, statuses: [Status] = []) -> GitHubPullFacts {
        GitHubPullFacts(state: state, merged: merged, draft: draft, mergeable: mergeable, mergeableState: mergeableState, head: head,
                        mergeCommit: merged ? mergeCommit : nil, baseRef: "main", checks: .listed(runs: runs, statuses: statuses))
    }

    @Test func readinessReadsThePullRequestItsCheckRunsAndItsStatuses() {
        let cases: [(pull: GitHubPullFacts, expected: MergeReadiness)] = [
            (Self.pull(), .ready(head: Self.head)),
            (Self.pull(statuses: [Self.status("ci/jenkins", "success")]), .ready(head: Self.head)),
            (Self.pull(mergeable: nil, mergeableState: "unknown"), .waiting("GitHub is checking it")),
            (Self.pull(mergeable: false), .waiting("GitHub is checking it")),
            (Self.pull(mergeableState: "unstable", runs: [Self.run("test", "in_progress", nil)]), .waiting("its checks are running")),
            (Self.pull(mergeableState: "unstable", runs: [Self.run("test", "completed", "failure")]), .blocked("its check test failed")),
            (Self.pull(mergeableState: "unstable", statuses: [Self.status("ci/jenkins", "failure")]), .blocked("its status ci/jenkins failed")),
            (Self.pull(mergeableState: "unstable", statuses: [Self.status("ci/jenkins", "pending")]), .waiting("its checks are running")),
            (Self.pull(mergeableState: "unstable", statuses: [Self.status("ci/jenkins", "success")]), .waiting("GitHub says its checks are not all passing")),
            (Self.pull(mergeable: false, mergeableState: "dirty"), .blocked("it has conflicts")),
            (Self.pull(mergeableState: "behind"), .blocked("it is behind its base branch")),
            (Self.pull(mergeableState: "blocked"), .waiting("it needs a review or a required check")),
            (Self.pull(mergeableState: "something_new"), .waiting("GitHub is checking it")),
            (Self.pull(draft: true, mergeableState: "draft"), .blocked("it is a draft")),
            // A draft's checks are read first: what else stops it is said before the draft, which is marked ready only
            // when nothing else does.
            (Self.pull(draft: true, mergeableState: "draft", runs: [Self.run("test", "completed", "failure")]), .blocked("its check test failed")),
            (Self.pull(draft: true, mergeableState: "draft", runs: [Self.run("test", "in_progress", nil)]), .waiting("its checks are running")),
            // Many CIs skip their checks on a draft: skipped passes, as GitHub counts it, so the draft is all that stops it
            // and it is marked ready; its checks then run. A conflict a draft already shows still stops it.
            (Self.pull(draft: true, mergeableState: "draft", runs: [Self.run("test", "completed", "skipped")]), .blocked("it is a draft")),
            (Self.pull(draft: true, mergeableState: "draft", runs: [Self.run("test", "completed", "skipped"), Self.run("lint", "completed", "failure")]),
             .blocked("its check lint failed")),
            (Self.pull(draft: true, mergeable: false, mergeableState: "draft"), .blocked("it has conflicts")),
            (Self.pull(state: "closed", merged: true), .merged(commit: Self.mergeCommit, head: Self.head, target: "main")),
            (Self.pull(state: "closed"), .blocked("the pull request is closed")),
        ]
        for item in cases {
            #expect(MergeReadiness.gitHub(item.pull) == item.expected, "\(item.expected)")
        }
    }

    /// Both readings of a head's checks come from one table, GitHub's own (neutral and skipped pass, as branch protection
    /// counts them), so the merge and the pipeline word never disagree: a failed check blocks and is `failure`, one still
    /// running or with a conclusion AiTerm does not know waits and is `pending`, and only green reaches `mergeable_state`
    /// and is `success`. A failed check is said before a running one.
    @Test func theMergeAndThePipelineWordReadEveryCheckTheSameWay() {
        let running = MergeReadiness.waiting("its checks are running")
        var cases: [(runs: [Run], statuses: [Status], readiness: MergeReadiness, pipeline: String)] = [
            ("neutral", MergeReadiness.ready(head: Self.head), "success"), ("skipped", .ready(head: Self.head), "success"),
            ("stale", .blocked("its check lint went stale"), "failure"), ("action_required", .blocked("its check lint needs someone to act"), "failure"),
            ("cancelled", .blocked("its check lint was cancelled"), "failure"), ("timed_out", .blocked("its check lint failed"), "failure"),
            ("startup_failure", .blocked("its check lint failed"), "failure"), ("failure", .blocked("its check lint failed"), "failure"),
            ("a_new_conclusion", running, "pending"),
        ].map { ([Self.run("test", "completed", "success"), Self.run("lint", "completed", $0.0)], [], $0.1, $0.2) }
        cases += [
            ([Self.run("lint", "completed", nil)], [], running, "pending"),
            ([Self.run("lint", "in_progress", nil), Self.run("test", "completed", "failure")], [], .blocked("its check test failed"), "failure"),
        ]
        cases += ["queued", "in_progress", "pending", "waiting", "requested"].map {
            ([Self.run("test", "completed", "success"), Self.run("lint", $0, nil)], [], running, "pending")
        }
        cases += [("success", MergeReadiness.ready(head: Self.head), "success"), ("pending", running, "pending"), ("a_new_state", running, "pending"),
                  ("failure", .blocked("its status ci/jenkins failed"), "failure"), ("error", .blocked("its status ci/jenkins failed"), "failure")]
            .map { (Self.green, [Self.status("ci/jenkins", $0.0)], $0.1, $0.2) }
        for item in cases {
            let pull = Self.pull(runs: item.runs, statuses: item.statuses)
            #expect(MergeReadiness.gitHub(pull) == item.readiness, "\(item.runs) \(item.statuses)")
            #expect(pull.checks.pipeline == item.pipeline, "\(item.runs) \(item.statuses)")
        }
    }

    /// The pipeline word for a draft's checks, as the merge watch reads it; no checks at all is no word, so never green.
    @Test func thePipelineWordIsFailurePendingSuccessOrNone() {
        #expect(Self.pull(draft: true, mergeableState: "draft", runs: [Self.run("test", "completed", "success"), Self.run("lint", "completed", "failure")])
            .checks.pipeline == "failure")
        #expect(Self.pull(draft: true, mergeableState: "draft", runs: [Self.run("test", "completed", "success"), Self.run("lint", "in_progress", nil)])
            .checks.pipeline == "pending")
        #expect(Self.pull().checks.pipeline == "success")
        #expect(Self.pull(draft: true, mergeableState: "draft", statuses: [Self.status("ci/jenkins", "failure")]).checks.pipeline == "failure")
        #expect(Self.pull(draft: true, mergeableState: "draft", runs: []).checks.pipeline == nil, "no checks at all is no pipeline")
    }

    /// Checks that could not be listed whole are not green: the pull waits and has no pipeline word.
    @Test func checksNotListedWholeWaitWithNoPipeline() {
        var pull = Self.pull()
        pull.checks = .notListedWhole
        #expect(MergeReadiness.gitHub(pull) == .waiting("GitHub has not listed all its checks"))
        #expect(pull.checks.pipeline == nil)
    }
}
