import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// GitHub's write calls for finish_task, against response bodies recorded from GitHub's REST API
/// (2022-11-28), trimmed to the fields AiTerm reads plus a few it does not.
@Suite struct GitHubPublishTests {
    let config = GitHubConfig(token: "ghp_tok")
    static let head = "4f2a91c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6"
    static let mergeCommit = "9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d"
    static let api = "https://api.github.com/repos/octocat/hello"

    static func pull(state: String = "open", draft: Bool = false, merged: Bool = false,
                     mergeable: String = "true", mergeableState: String = "clean",
                     headRepo: String? = "octocat/hello", headLabel: String = "octocat:feat/pluto-231") -> String {
        """
        {"url":"\(api)/pulls/88","id":1,"number":88,"state":"\(state)","title":"PLUTO-231 Add gift card",
         "user":{"login":"laurens"},"body":"Opened by AiTerm","draft":\(draft),"html_url":"https://github.com/octocat/hello/pull/88",
         "head":{"label":"\(headLabel)","ref":"feat/pluto-231","sha":"\(head)","repo":\(headRepo.map { #"{"full_name":"\#($0)"}"# } ?? "null")},
         "base":{"label":"octocat:main","ref":"main","sha":"0b1c","repo":{"full_name":"octocat/hello"}},
         "merged":\(merged),"mergeable":\(mergeable),"mergeable_state":"\(mergeableState)",
         "merge_commit_sha":\(merged ? "\"\(mergeCommit)\"" : "null")}
        """
    }
    /// `total` is what GitHub says it holds in all, which is more than `runs` when a page of it is shown.
    static func runs(_ runs: [(name: String, status: String, conclusion: String?)], total: Int? = nil) -> String {
        let items = runs.map { run in
            let conclusion = run.conclusion.map { "\"\($0)\"" } ?? "null"
            return #"{"id":1,"name":"\#(run.name)","status":"\#(run.status)","conclusion":\#(conclusion)}"#
        }
        return #"{"total_count":\#(total ?? runs.count),"check_runs":[\#(items.joined(separator: ","))]}"#
    }
    static func statuses(_ statuses: [(context: String, state: String)]) -> String {
        let items = statuses.map { #"{"context":"\#($0.context)","state":"\#($0.state)"}"# }
        let overall = statuses.isEmpty ? "pending" : (statuses.allSatisfy { $0.state == "success" } ? "success" : "failure")
        return #"{"state":"\#(overall)","total_count":\#(statuses.count),"statuses":[\#(items.joined(separator: ","))]}"#
    }
    static let green = runs([("test", "completed", "success")])

    /// A host answering the pull request, its check runs and its combined status, each at its own path.
    private func host(pull: String, checkRuns: String = Self.green, status: String = Self.statuses([])) -> StubURLProtocol.Handler {
        { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/check-runs") { return (200, Data(checkRuns.utf8)) }
            if path.hasSuffix("/status") { return (200, Data(status.utf8)) }
            return (200, Data(pull.utf8))
        }
    }

    private func makeClient(_ handler: @escaping StubURLProtocol.Handler) -> (client: GitHubClient, stub: StubSession) {
        let stub = StubSession(handler: handler)
        return (GitHubClient(config: config, session: stub.session), stub)
    }

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func page(_ request: URLRequest) -> Int {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
        return items?.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 1
    }

    // MARK: Opening and finding

    @Test func aDraftIsOpenedFromTheTasksBranch() async throws {
        let (client, stub) = makeClient { _ in (201, Data(Self.pull(draft: true, mergeable: "null", mergeableState: "unknown").utf8)) }
        let request = try await client.createPullRequest(repo: "octocat/hello", source: "feat/pluto-231", target: "main",
                                                         title: "PLUTO-231 Add gift card", body: "Opened by AiTerm", draft: true)
        #expect(request.iid == 88)
        #expect(request.draft)
        #expect(request.targetBranch == "main")
        #expect(request.url == "https://github.com/octocat/hello/pull/88")
        let sent = try #require(stub.lastRequest)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == Self.api + "/pulls")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_tok")
        let fields = try body(sent)
        #expect(fields["head"] as? String == "feat/pluto-231")
        #expect(fields["base"] as? String == "main")
        #expect(fields["title"] as? String == "PLUTO-231 Add gift card")
        #expect(fields["body"] as? String == "Opened by AiTerm")
        #expect(fields["draft"] as? Bool == true)
        #expect(Set(fields.keys) == ["head", "base", "title", "body", "draft"], "nothing else is asked of GitHub")
    }

    @Test func aPullRequestThatIsNotADraftIsOpenedAsOne() async throws {
        let (client, stub) = makeClient { _ in (201, Data(Self.pull().utf8)) }
        let request = try await client.createPullRequest(repo: "octocat/hello", source: "feat/pluto-231", target: "feat/parent",
                                                         title: "t", body: "b", draft: false)
        #expect(!request.draft)
        #expect(try body(stub.lastRequest)["draft"] as? Bool == false)
        #expect(try body(stub.lastRequest)["base"] as? String == "feat/parent")
    }

    @Test func theOpenPullRequestFromABranchIsFoundNotOpenedAgain() async throws {
        let (client, stub) = makeClient { _ in (200, Data(("[" + Self.pull() + "]").utf8)) }
        let found = try await client.openPullRequest(repo: "octocat/hello", source: "feat/pluto-231")
        #expect(found?.iid == 88)
        #expect(found?.targetBranch == "main", "the request says where it points, for a stacked task to compare")
        let url = try #require(stub.lastRequest?.url?.absoluteString)
        #expect(url.hasPrefix(Self.api + "/pulls?"))
        #expect(url.contains("state=open"))
        #expect(url.contains("head=octocat:feat/pluto-231"))
        let (none, _) = makeClient { _ in (200, Data("[]".utf8)) }
        #expect(try await none.openPullRequest(repo: "octocat/hello", source: "feat/x") == nil)
    }

    @Test func aForksPullRequestOfTheSameBranchNameIsNotTheTasks() async throws {
        let fork = Self.pull(headRepo: "mallory/hello", headLabel: "mallory:feat/pluto-231")
        let deleted = Self.pull(headRepo: nil)
        for entry in [fork, deleted] {
            let (client, _) = makeClient { _ in (200, Data(("[" + entry + "]").utf8)) }
            #expect(try await client.openPullRequest(repo: "octocat/hello", source: "feat/pluto-231") == nil)
        }
        let (both, _) = makeClient { _ in (200, Data(("[" + fork + "," + Self.pull() + "]").utf8)) }
        #expect(try await both.openPullRequest(repo: "octocat/hello", source: "feat/pluto-231")?.forkHead == nil)
    }

    @Test func anEntryThatCannotBeReadIsNoAnswerNotNone() async throws {
        for listing in [#"[{"number":"eighty-eight"}]"#, "[" + Self.pull() + #",{"oops":true}]"#, #"{"message":"not a list"}"#] {
            await #expect(throws: GitHubError.decoding) {
                _ = try await self.makeClient { _ in (200, Data(listing.utf8)) }.client.openPullRequest(repo: "octocat/hello", source: "feat/pluto-231")
            }
        }
        await #expect(throws: GitHubError.forbidden) {
            _ = try await self.makeClient { _ in (403, Data()) }.client.openPullRequest(repo: "octocat/hello", source: "feat/x")
        }
        await #expect(throws: GitHubError.repoNotFound("octocat")) {
            _ = try await self.makeClient { _ in (200, Data("[]".utf8)) }.client.openPullRequest(repo: "octocat", source: "feat/x")
        }
    }

    // MARK: Readiness

    @Test func readinessReadsThePullRequestItsCheckRunsAndItsStatuses() async throws {
        let cases: [(pull: String, runs: String, status: String, expected: MergeReadiness)] = [
            (Self.pull(), Self.green, Self.statuses([]), .ready(head: Self.head)),
            (Self.pull(), Self.green, Self.statuses([("ci/jenkins", "success")]), .ready(head: Self.head)),
            (Self.pull(mergeable: "null", mergeableState: "unknown"), Self.green, Self.statuses([]), .waiting("GitHub is checking it")),
            (Self.pull(mergeable: "false"), Self.green, Self.statuses([]), .waiting("GitHub is checking it")),
            (Self.pull(mergeableState: "unstable"), Self.runs([("test", "in_progress", nil)]), Self.statuses([]), .waiting("its checks are running")),
            (Self.pull(mergeableState: "unstable"), Self.runs([("test", "completed", "failure")]), Self.statuses([]), .blocked("its check test failed")),
            (Self.pull(mergeableState: "unstable"), Self.green, Self.statuses([("ci/jenkins", "failure")]), .blocked("its status ci/jenkins failed")),
            (Self.pull(mergeableState: "unstable"), Self.green, Self.statuses([("ci/jenkins", "pending")]), .waiting("its checks are running")),
            (Self.pull(mergeableState: "unstable"), Self.green, Self.statuses([("ci/jenkins", "success")]), .waiting("GitHub says its checks are not all passing")),
            (Self.pull(mergeable: "false", mergeableState: "dirty"), Self.green, Self.statuses([]), .blocked("it has conflicts")),
            (Self.pull(mergeableState: "behind"), Self.green, Self.statuses([]), .blocked("it is behind its base branch")),
            (Self.pull(mergeableState: "blocked"), Self.green, Self.statuses([]), .waiting("it needs a review or a required check")),
            (Self.pull(mergeableState: "something_new"), Self.green, Self.statuses([]), .waiting("GitHub is checking it")),
            (Self.pull(draft: true, mergeableState: "draft"), Self.green, Self.statuses([]), .blocked("it is a draft")),
            // A draft's checks are read first: what else stops it is said before the draft, which is marked ready only
            // when nothing else does.
            (Self.pull(draft: true, mergeableState: "draft"), Self.runs([("test", "completed", "failure")]), Self.statuses([]), .blocked("its check test failed")),
            (Self.pull(draft: true, mergeableState: "draft"), Self.runs([("test", "in_progress", nil)]), Self.statuses([]), .waiting("its checks are running")),
            // Many CIs skip their checks on a draft: skipped is no failure while it is one, so the draft is all that stops it
            // and it is marked ready; its checks then run. A conflict a draft already shows still stops it.
            (Self.pull(draft: true, mergeableState: "draft"), Self.runs([("test", "completed", "skipped")]), Self.statuses([]), .blocked("it is a draft")),
            (Self.pull(draft: true, mergeableState: "draft"), Self.runs([("test", "completed", "skipped"), ("lint", "completed", "failure")]), Self.statuses([]),
             .blocked("its check lint failed")),
            (Self.pull(draft: true, mergeable: "false", mergeableState: "draft"), Self.green, Self.statuses([]), .blocked("it has conflicts")),
            (Self.pull(state: "closed", merged: true), Self.green, Self.statuses([]), .merged(commit: Self.mergeCommit, head: Self.head, target: "main")),
            (Self.pull(state: "closed"), Self.green, Self.statuses([]), .blocked("the pull request is closed")),
        ]
        for item in cases {
            let (client, stub) = makeClient(host(pull: item.pull, checkRuns: item.runs, status: item.status))
            #expect(try await client.mergeReadiness(repo: "octocat/hello", number: 88) == item.expected, "\(item.expected)")
            #expect(stub.requests.first?.url?.absoluteString == Self.api + "/pulls/88")
        }
    }

    /// What the Operator reads of a pull request (`run_status`): draft, the checks as one word, GitHub's `mergeable_state`, approvals.
    @Test func gitHubStateReadsDraftChecksMergeabilityAndApprovals() async throws {
        func state(runs: String, statuses: String = Self.statuses([]), draft: Bool = true, mergeableState: String = "draft") async throws -> MergeRequestState {
            let (client, _) = makeClient { request in
                let path = request.url?.path ?? ""
                if path.hasSuffix("/check-runs") { return (200, Data(runs.utf8)) }
                if path.hasSuffix("/status") { return (200, Data(statuses.utf8)) }
                if path.hasSuffix("/reviews") {
                    return (200, Data((Self.page(request) == 1 ? #"[{"user":{"login":"alice"},"state":"APPROVED"}]"# : "[]").utf8))
                }
                return (200, Data(Self.pull(draft: draft, mergeableState: mergeableState).utf8))
            }
            let request = MergeRequest(iid: 88, title: "PLUTO-231", sourceBranch: "feat/pluto-231", targetBranch: "main", author: nil,
                                       state: "open", draft: false, url: "https://github.com/octocat/hello/pull/88")
            return try await GitHubPublisher(client: client, repo: "octocat/hello").state(of: request)
        }
        let failing = try await state(runs: Self.runs([("test", "completed", "success"), ("lint", "completed", "failure")]))
        #expect(failing == MergeRequestState(iid: 88, url: "https://github.com/octocat/hello/pull/88", draft: true, pipeline: "failure",
                                             mergeable: "draft", approvedBy: ["alice"], head: Self.head))
        #expect(try await state(runs: Self.runs([("test", "completed", "success"), ("lint", "in_progress", nil)])).pipeline == "pending")
        #expect(try await state(runs: Self.green, draft: false, mergeableState: "clean").pipeline == "success")
        #expect(try await state(runs: Self.green, statuses: Self.statuses([("ci/jenkins", "failure")])).pipeline == "failure")
        #expect(try await state(runs: Self.runs([])).pipeline == nil, "no checks at all is no pipeline")
    }

    /// Neutral, skipped and action-required checks are not passes, and a check or status still pending is
    /// not done: none of them reads ready, whatever `mergeable_state` says.
    @Test func aCheckThatIsNotAPassIsNeverGreen() async throws {
        let blocked: [(String, String)] = [("neutral", "its check lint did not pass (neutral)"), ("skipped", "its check lint did not pass (skipped)"),
                                           ("stale", "its check lint did not pass (stale)"), ("action_required", "its check lint needs someone to act"),
                                           ("cancelled", "its check lint was cancelled"), ("timed_out", "its check lint failed"),
                                           ("startup_failure", "its check lint failed")]
        for (conclusion, why) in blocked {
            let (client, _) = makeClient(host(pull: Self.pull(), checkRuns: Self.runs([("test", "completed", "success"), ("lint", "completed", conclusion)])))
            #expect(try await client.mergeReadiness(repo: "octocat/hello", number: 88) == .blocked(why), "\(conclusion)")
        }
        for status in ["queued", "in_progress", "pending", "waiting", "requested"] {
            let (client, _) = makeClient(host(pull: Self.pull(), checkRuns: Self.runs([("test", "completed", "success"), ("lint", status, nil)])))
            #expect(try await client.mergeReadiness(repo: "octocat/hello", number: 88) == .waiting("its checks are running"), "\(status)")
        }
        // A conclusion AiTerm does not know, or none on a run that says it completed, waits.
        for conclusion in ["a_new_conclusion", nil] {
            let (client, _) = makeClient(host(pull: Self.pull(), checkRuns: Self.runs([("lint", "completed", conclusion)])))
            #expect(try await client.mergeReadiness(repo: "octocat/hello", number: 88) == .waiting("its checks are running"), "\(conclusion ?? "nil")")
        }
        for state in ["pending", "a_new_state"] {
            let (client, _) = makeClient(host(pull: Self.pull(), status: Self.statuses([("ci/jenkins", state)])))
            #expect(try await client.mergeReadiness(repo: "octocat/hello", number: 88) == .waiting("its checks are running"), "\(state)")
        }
    }

    @Test func aFailingCheckOnALaterPageIsStillSeen() async throws {
        let first = (1...100).map { (name: "job-\($0)", status: "completed", conclusion: Optional("success")) }
        let (client, stub) = makeClient { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/check-runs") {
                return (200, Data((Self.page(request) == 1 ? Self.runs(first, total: 101)
                                   : Self.runs([("deploy", "completed", "failure")], total: 101)).utf8))
            }
            if path.hasSuffix("/status") { return (200, Data(Self.statuses([]).utf8)) }
            return (200, Data(Self.pull().utf8))
        }
        #expect(try await client.mergeReadiness(repo: "octocat/hello", number: 88) == .blocked("its check deploy failed"))
        #expect(stub.requests.filter { $0.url?.path.hasSuffix("/check-runs") == true }.count == 2)
    }

    @Test func statusesAreReadToTheEndToo() async throws {
        let all = (1...100).map { (context: "ci/\($0)", state: "success") }
        let (client, _) = makeClient { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/check-runs") { return (200, Data(Self.green.utf8)) }
            if path.hasSuffix("/status") {
                let first = Self.page(request) == 1
                let body = first ? Self.statuses(all) : Self.statuses([("ci/last", "failure")])
                return (200, Data(body.replacingOccurrences(of: #""total_count":\#(first ? 100 : 1)"#, with: #""total_count":101"#).utf8))
            }
            return (200, Data(Self.pull().utf8))
        }
        #expect(try await client.mergeReadiness(repo: "octocat/hello", number: 88) == .blocked("its status ci/last failed"))
    }

    /// A list that never reaches its total, or ends short of it, is not green: it waits.
    @Test func checksThatCannotBeReadWholeNeverReadReady() async throws {
        let endless = makeClient { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/check-runs") { return (200, Data(Self.runs([("test", "completed", "success")], total: 100_000).utf8)) }
            if path.hasSuffix("/status") { return (200, Data(Self.statuses([]).utf8)) }
            return (200, Data(Self.pull().utf8))
        }
        #expect(try await endless.client.mergeReadiness(repo: "octocat/hello", number: 88) == .waiting("GitHub has not listed all its checks"))
        #expect(endless.stub.requests.count == 1 + GitHubClient.listedPages, "it gives up after the pages it reads")
        let short = makeClient(host(pull: Self.pull(), checkRuns: Self.runs([], total: 3)))
        #expect(try await short.client.mergeReadiness(repo: "octocat/hello", number: 88) == .waiting("GitHub has not listed all its checks"))
    }

    @Test func readinessThatCannotBeAskedThrows() async throws {
        for status in [401, 403, 404, 500] {
            await #expect(throws: GitHubError.self) {
                _ = try await self.makeClient { _ in (status, Data()) }.client.mergeReadiness(repo: "octocat/hello", number: 88)
            }
        }
        await #expect(throws: GitHubError.decoding) {
            _ = try await self.makeClient(self.host(pull: Self.pull(), checkRuns: #"{"check_runs":[]}"#)).client
                .mergeReadiness(repo: "octocat/hello", number: 88)
        }
        await #expect(throws: GitHubError.forbidden) {
            _ = try await self.makeClient { request in
                request.url?.path.hasSuffix("/status") == true ? (403, Data()) : (200, Data((request.url?.path.hasSuffix("/check-runs") == true ? Self.green : Self.pull()).utf8))
            }.client.mergeReadiness(repo: "octocat/hello", number: 88)
        }
    }

    // MARK: Merging and retargeting

    @Test func itIsMergedAtTheAcceptedCommit() async throws {
        let answer = #"{"sha":"\#(Self.mergeCommit)","merged":true,"message":"Pull Request successfully merged"}"#
        let (client, stub) = makeClient { _ in (200, Data(answer.utf8)) }
        #expect(try await client.merge(repo: "octocat/hello", number: 88, sha: Self.head) == .merged(commit: Self.mergeCommit, head: Self.head))
        let sent = try #require(stub.lastRequest)
        #expect(sent.httpMethod == "PUT")
        #expect(sent.url?.absoluteString == Self.api + "/pulls/88/merge")
        #expect(try body(sent) as NSDictionary == ["sha": Self.head], "only the accepted commit: no merge_method, no auto-merge, no title")
    }

    @Test func anAnswerThatDoesNotSayItMergedIsNotAMerge() async throws {
        for answer in [#"{"merged":false,"message":"queued"}"#, #"{"merged":true}"#, "{}"] {
            let (client, _) = makeClient { _ in (200, Data(answer.utf8)) }
            #expect(try await client.merge(repo: "octocat/hello", number: 88, sha: Self.head) == .waiting("GitHub has not finished merging it"), "\(answer)")
        }
    }

    @Test func aRefusedMergeIsBlockedNotThrown() async throws {
        let (moved, _) = makeClient { _ in (409, Data(#"{"message":"Head branch was modified. Review and try the merge again."}"#.utf8)) }
        #expect(try await moved.merge(repo: "octocat/hello", number: 88, sha: Self.head) == .blocked("the branch moved past the accepted commit"))
        for status in [405, 422] {
            let (client, _) = makeClient { _ in (status, Data(#"{"message":"Pull Request is not mergeable"}"#.utf8)) }
            #expect(try await client.merge(repo: "octocat/hello", number: 88, sha: Self.head) == .blocked("GitHub refused to merge it (HTTP \(status))"))
        }
        await #expect(throws: GitHubError.unauthorized) {
            _ = try await self.makeClient { _ in (401, Data()) }.client.merge(repo: "octocat/hello", number: 88, sha: Self.head)
        }
        await #expect(throws: GitHubError.badResponse(502)) {
            _ = try await self.makeClient { _ in (502, Data()) }.client.merge(repo: "octocat/hello", number: 88, sha: Self.head)
        }
    }

    @Test func aPullRequestIsRetargeted() async throws {
        let (client, stub) = makeClient { _ in (200, Data(Self.pull().utf8)) }
        try await client.retarget(repo: "octocat/hello", number: 88, to: "main")
        let sent = try #require(stub.lastRequest)
        #expect(sent.httpMethod == "PATCH")
        #expect(sent.url?.absoluteString == Self.api + "/pulls/88")
        #expect(try body(sent) as NSDictionary == ["base": "main"])
        await #expect(throws: GitHubError.badResponse(422)) {
            _ = try await self.makeClient { _ in (422, Data()) }.client.retarget(repo: "octocat/hello", number: 88, to: "gone")
        }
    }

    // MARK: Protection

    static let noRules = #"{"data":{"repository":{"branchProtectionRules":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}"#
    static func rules(_ patterns: [String], next: String? = nil) -> String {
        let nodes = patterns.map { #"{"pattern":"\#($0)"}"# }.joined(separator: ",")
        let page = next.map { #"{"hasNextPage":true,"endCursor":"\#($0)"}"# } ?? #"{"hasNextPage":false,"endCursor":null}"#
        return #"{"data":{"repository":{"branchProtectionRules":{"pageInfo":\#(page),"nodes":[\#(nodes)]}}}}"#
    }
    static let notThere = #"{"message":"Branch not found"}"#
    static func branch(protected: Bool, name: String = "feat/pluto-231") -> String { #"{"name":"\#(name)","protected":\#(protected),"commit":{"sha":"\#(head)"}}"# }

    /// GitHub answering a branch's rulesets (`/rules/branches/…`, `rulesets` being page 1 and every other
    /// page empty), the branch itself (`/branches/…`, a 404 for one not pushed yet) and its classic
    /// protection rules' patterns (GraphQL). `fail` sends one source a status instead of its answer.
    private func protectionHost(rulesets: String = "[]", branch: (Int, String) = (404, Self.notThere), patterns: String = Self.noRules,
                                fail: [String: Int] = [:]) -> StubURLProtocol.Handler {
        { request in
            let path = request.url?.path ?? ""
            if path.contains("/rules/branches/") { return (fail["rulesets"] ?? 200, Data((Self.page(request) == 1 ? rulesets : "[]").utf8)) }
            if path.hasSuffix("/graphql") { return (fail["graphql"] ?? 200, Data(patterns.utf8)) }
            return (fail["branch"] ?? branch.0, Data(branch.1.utf8))
        }
    }

    @Test func aBranchGitHubProtectsIsSaid() async throws {
        let pullRequestRule = #"[{"type":"pull_request","ruleset_source_type":"Repository","ruleset_source":"octocat/hello","ruleset_id":7,"parameters":{"required_approving_review_count":1}}]"#
        let (byRuleset, stub) = makeClient(protectionHost(rulesets: pullRequestRule))
        #expect(try await byRuleset.branchProtection(repo: "octocat/hello", branch: "feat/pluto-231") == .protected("a ruleset’s pull request rule covers it"))
        #expect(stub.requests.first?.url?.absoluteString.hasPrefix(Self.api + "/rules/branches/feat%2Fpluto-231?") == true,
                "a slash in the branch stays inside its path segment")

        let classic = (200, Self.branch(protected: true))
        #expect(try await makeClient(protectionHost(branch: classic)).client.branchProtection(repo: "octocat/hello", branch: "feat/pluto-231")
                == .protected("GitHub’s branch protection covers it"))

        let pattern = Self.rules(["feat/*"])
        #expect(try await makeClient(protectionHost(patterns: pattern)).client.branchProtection(repo: "octocat/hello", branch: "feat/pluto-231")
                == .protected("the branch protection rule feat/* covers it"))
        #expect(try await makeClient(protectionHost(patterns: pattern)).client.branchProtection(repo: "octocat/hello", branch: "feat/pluto/231")
                == .unprotected, "GitHub's * stops at a slash")
        #expect(try await makeClient(protectionHost(branch: classic)).client.branchProtection(repo: "octocat/hello", branch: "refs/heads/feat/pluto-231")
                == .protected("GitHub’s branch protection covers it"), "a full ref names the same branch")
    }

    @Test func aRulesetRuleOtherThanAHarmlessOneProtects() async throws {
        let named = ["update", "creation", "pull_request", "required_status_checks", "required_deployments", "merge_queue",
                     "workflows", "code_scanning"]
        // A type GitHub has not announced yet is protection too, never harmless by default.
        for type in named + ["a_rule_from_the_future"] {
            let rule = #"[{"type":"\#(type)","ruleset_source_type":"Organization","ruleset_source":"octocat","ruleset_id":1}]"#
            let (client, _) = makeClient(protectionHost(rulesets: rule, branch: (200, Self.branch(protected: false, name: "feat/x"))))
            #expect(try await client.branchProtection(repo: "octocat/hello", branch: "feat/x")
                    == .protected("a ruleset’s \(type.replacingOccurrences(of: "_", with: " ")) rule covers it"), "\(type)")
        }
        // One harmless rule beside a protective one does not hide it.
        let both = #"[{"type":"deletion"},{"type":"workflows"}]"#
        #expect(try await makeClient(protectionHost(rulesets: both)).client.branchProtection(repo: "octocat/hello", branch: "feat/x")
                == .protected("a ruleset’s workflows rule covers it"))
    }

    @Test func everyHarmlessRulesetRuleLeavesTheBranchToTheOtherSources() async throws {
        for type in GitHubClient.harmlessRules {
            let rule = #"[{"type":"\#(type)","ruleset_source_type":"Organization","ruleset_source":"octocat","ruleset_id":1}]"#
            let (client, _) = makeClient(protectionHost(rulesets: rule, branch: (200, Self.branch(protected: false, name: "feat/x"))))
            #expect(try await client.branchProtection(repo: "octocat/hello", branch: "feat/x") == .unprotected, "\(type)")
        }
        #expect(GitHubClient.harmlessRules.count == 12)
    }

    @Test func aBranchThatWasRenamedIsNotAnsweredForByItsNewNamesFlag() async throws {
        let (client, _) = makeClient(protectionHost(branch: (200, Self.branch(protected: false, name: "feat/renamed"))))
        await #expect(throws: ProtectionUnknown.self) {
            _ = try await client.branchProtection(repo: "octocat/hello", branch: "feat/old")
        }
    }

    @Test func aPlusInABranchIsSentAsAPlus() async throws {
        let (client, stub) = makeClient { _ in (200, Data("[]".utf8)) }
        #expect(try await client.openPullRequest(repo: "octocat/hello", source: "feat/a+b") == nil)
        let url = try #require(stub.lastRequest?.url?.absoluteString)
        #expect(url.contains("head=octocat:feat/a%2Bb"))
        #expect(!url.contains("+"))
    }

    @Test func aRuleThatOnlyForbidsForcePushesProtectsNothingAiTermDoes() async throws {
        let noForce = #"[{"type":"non_fast_forward","ruleset_source_type":"Organization","ruleset_source":"octocat","ruleset_id":1},{"type":"deletion","ruleset_source_type":"Organization","ruleset_source":"octocat","ruleset_id":1}]"#
        let unprotected = (200, Self.branch(protected: false))
        #expect(try await makeClient(protectionHost(rulesets: noForce, branch: unprotected)).client
                .branchProtection(repo: "octocat/hello", branch: "feat/pluto-231") == .unprotected)
    }

    /// A page that comes back short proves nothing: the guarding rule is on the second one.
    @Test func rulesetsAreReadUntilAnEmptyPage() async throws {
        let (client, stub) = makeClient { request in
            let path = request.url?.path ?? ""
            if path.contains("/rules/branches/") {
                switch Self.page(request) {
                case 1: return (200, Data(#"[{"type":"deletion"}]"#.utf8))
                case 2: return (200, Data(#"[{"type":"required_status_checks"}]"#.utf8))
                default: return (200, Data("[]".utf8))
                }
            }
            return (200, Data(Self.noRules.utf8))
        }
        #expect(try await client.branchProtection(repo: "octocat/hello", branch: "feat/x") == .protected("a ruleset’s required status checks rule covers it"))
        #expect(stub.requests.count == 2)
        let endless = makeClient { _ in (200, Data(#"[{"type":"deletion"}]"#.utf8)) }
        await #expect(throws: ProtectionUnknown.tooManyRules(GitHubClient.listedPages * 100)) {
            _ = try await endless.client.branchProtection(repo: "octocat/hello", branch: "feat/x")
        }
        #expect(endless.stub.requests.count == GitHubClient.listedPages)
    }

    @Test func aBranchGitHubDoesNotHaveYetIsAskedByItsRulesPatterns() async throws {
        let (client, stub) = makeClient(protectionHost(patterns: Self.rules(["release/*", "main"])))
        #expect(try await client.branchProtection(repo: "octocat/hello", branch: "feat/a b") == .unprotected)
        let urls = stub.requests.compactMap { $0.url?.absoluteString }
        #expect(urls.contains { $0.hasPrefix(Self.api + "/branches/feat%2Fa%20b") }, "a branch is asked for in one segment")
        #expect(urls.last == "https://api.github.com/graphql")
        // An existing branch is answered by its own flag: no pattern is read for it.
        let (existing, existingStub) = makeClient(protectionHost(branch: (200, Self.branch(protected: false))))
        #expect(try await existing.branchProtection(repo: "octocat/hello", branch: "feat/pluto-231") == .unprotected)
        #expect(existingStub.requests.allSatisfy { $0.url?.path != "/graphql" })
    }

    @Test func classicPatternsAreReadPageByPage() async throws {
        let (client, stub) = makeClient { request in
            let path = request.url?.path ?? ""
            if path.contains("/rules/branches/") { return (200, Data("[]".utf8)) }
            if path.hasSuffix("/graphql") {
                let sent = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                return (200, Data((sent.contains("cursor-1") ? Self.rules(["feat/*"]) : Self.rules(["main"], next: "cursor-1")).utf8))
            }
            return (404, Data(Self.notThere.utf8))
        }
        #expect(try await client.branchProtection(repo: "octocat/hello", branch: "feat/x") == .protected("the branch protection rule feat/* covers it"))
        #expect(stub.requests.filter { $0.url?.path == "/graphql" }.count == 2)
        let endless = makeClient(protectionHost(patterns: Self.rules(["a"], next: "more")))
        await #expect(throws: ProtectionUnknown.self) {
            _ = try await endless.client.branchProtection(repo: "octocat/hello", branch: "feat/x")
        }
        let stuck = makeClient(protectionHost(patterns: Self.rules(["a"], next: "same")))
        await #expect(throws: ProtectionUnknown.self) {
            _ = try await stuck.client.branchProtection(repo: "octocat/hello", branch: "feat/x")
        }
        #expect(stuck.stub.requests.filter { $0.url?.path == "/graphql" }.count == 2, "a cursor that repeats stops it")
    }

    @Test func aPatternAiTermCannotReadIsNoAnswerUnlessAnotherRuleCoversTheBranch() async throws {
        let (client, _) = makeClient(protectionHost(patterns: Self.rules(["[z-a]", "feat/other"])))
        await #expect(throws: ProtectionUnknown.unreadable("AiTerm cannot read the branch pattern [z-a]")) {
            _ = try await client.branchProtection(repo: "octocat/hello", branch: "feat/x")
        }
        let (covered, _) = makeClient(protectionHost(patterns: Self.rules(["[z-a]", "feat/*"])))
        #expect(try await covered.branchProtection(repo: "octocat/hello", branch: "feat/x") == .protected("the branch protection rule feat/* covers it"))
    }

    /// What cannot be read is no answer: the caller pushes nothing.
    @Test func protectionThatCannotBeReadThrows() async throws {
        let hidden = #"{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository"}]}"#
        await #expect(throws: ProtectionUnknown.self) {
            _ = try await self.makeClient(self.protectionHost(patterns: hidden)).client.branchProtection(repo: "octocat/hello", branch: "feat/x")
        }
        let partial = #"{"data":{"repository":{"branchProtectionRules":{"pageInfo":{"hasNextPage":false},"nodes":[]}}},"errors":[{"message":"Something went wrong"}]}"#
        await #expect(throws: ProtectionUnknown.self) {
            _ = try await self.makeClient(self.protectionHost(patterns: partial)).client.branchProtection(repo: "octocat/hello", branch: "feat/x")
        }
        for repo in ["octocat", "octocat/hello/more", "/hello", ""] {
            await #expect(throws: ProtectionUnknown.self) {
                _ = try await self.makeClient(self.protectionHost()).client.branchProtection(repo: repo, branch: "feat/x")
            }
        }
        await #expect(throws: ProtectionUnknown.self) {
            _ = try await self.makeClient(self.protectionHost()).client.branchProtection(repo: "octocat/hello", branch: "")
        }
    }

    /// Each source, failing on its own, with every status that is not an answer, and with an answer that is
    /// not what was asked for: `ProtectionUnknown`, never `.unprotected`.
    @Test func everySourceThatFailsLeavesProtectionUnknown() async throws {
        for source in ["rulesets", "branch", "graphql"] {
            for status in [401, 403, 404, 429, 500, 502] where !(source == "branch" && status == 404) {
                await #expect(throws: ProtectionUnknown.self, "\(source) \(status)") {
                    _ = try await self.makeClient(self.protectionHost(fail: [source: status])).client
                        .branchProtection(repo: "octocat/hello", branch: "feat/x")
                }
            }
        }
        let garbled: [(String, StubURLProtocol.Handler)] = [
            ("rulesets", protectionHost(rulesets: #"{"message":"nope"}"#)),
            ("a rule without a type", protectionHost(rulesets: #"[{"ruleset_id":1}]"#)),
            ("a branch without its flag", protectionHost(branch: (200, #"{"name":"feat/x"}"#))),
            ("graphql", protectionHost(patterns: "not json")),
            ("a pattern without its text", protectionHost(patterns: #"{"data":{"repository":{"branchProtectionRules":{"pageInfo":{"hasNextPage":false},"nodes":[{}]}}}}"#)),
        ]
        for (what, handler) in garbled {
            await #expect(throws: ProtectionUnknown.self, "\(what)") {
                _ = try await self.makeClient(handler).client.branchProtection(repo: "octocat/hello", branch: "feat/x")
            }
        }
        // The same sources, each answering as it does for a branch that is not protected, are unprotected.
        #expect(try await makeClient(protectionHost()).client.branchProtection(repo: "octocat/hello", branch: "feat/x") == .unprotected)
        #expect(try await makeClient(protectionHost(branch: (200, Self.branch(protected: false, name: "feat/x")))).client
                .branchProtection(repo: "octocat/hello", branch: "feat/x") == .unprotected)
    }
}
