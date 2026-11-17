import Foundation
import Testing
import Synchronization
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

    private func makeClient(repo: String = "octocat/hello", _ handler: @escaping StubURLProtocol.Handler) -> (client: GitHubClient, stub: StubSession) {
        let stub = StubSession(handler: handler)
        return (GitHubClient(config: config, repo: repo, session: stub.session), stub)
    }

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func page(_ request: URLRequest) -> Int {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
        return items?.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 1
    }

    // MARK: Finding requests

    @Test func theOpenPullRequestFromABranchIsFoundNotOpenedAgain() async throws {
        let (client, stub) = makeClient { _ in (200, Data(("[" + Self.pull() + "]").utf8)) }
        let found = try await client.existingRequest(from: "feat/pluto-231")
        #expect(found?.iid == 88)
        #expect(found?.targetBranch == "main", "the request says where it points, for a stacked task to compare")
        let url = try #require(stub.lastRequest?.url?.absoluteString)
        #expect(url.hasPrefix(Self.api + "/pulls?"))
        #expect(url.contains("state=open"))
        #expect(url.contains("head=octocat:feat/pluto-231"))
        let (none, _) = makeClient { _ in (200, Data("[]".utf8)) }
        #expect(try await none.existingRequest(from: "feat/x") == nil)
    }

    @Test func aForksPullRequestOfTheSameBranchNameIsNotTheTasks() async throws {
        let fork = Self.pull(headRepo: "mallory/hello", headLabel: "mallory:feat/pluto-231")
        let deleted = Self.pull(headRepo: nil)
        for entry in [fork, deleted] {
            let (client, _) = makeClient { _ in (200, Data(("[" + entry + "]").utf8)) }
            #expect(try await client.existingRequest(from: "feat/pluto-231") == nil)
        }
        let (both, _) = makeClient { _ in (200, Data(("[" + fork + "," + Self.pull() + "]").utf8)) }
        #expect(try await both.existingRequest(from: "feat/pluto-231")?.forkHead == nil)
    }

    @Test func anEntryThatCannotBeReadIsNoAnswerNotNone() async throws {
        for listing in [#"[{"number":"eighty-eight"}]"#, "[" + Self.pull() + #",{"oops":true}]"#, #"{"message":"not a list"}"#] {
            await #expect(throws: GitHubError.decoding) {
                _ = try await self.makeClient { _ in (200, Data(listing.utf8)) }.client.existingRequest(from: "feat/pluto-231")
            }
        }
        await #expect(throws: GitHubError.forbidden) {
            _ = try await self.makeClient { _ in (403, Data()) }.client.existingRequest(from: "feat/x")
        }
        await #expect(throws: GitHubError.repoNotFound("octocat")) {
            _ = try await self.makeClient(repo: "octocat") { _ in (200, Data("[]".utf8)) }.client.existingRequest(from: "feat/x")
        }
    }

    // MARK: Status

    /// A host for a status read: the pull's reviews answer none, everything else goes to `handler`.
    private func statusClient(_ handler: @escaping StubURLProtocol.Handler) -> (client: GitHubClient, stub: StubSession) {
        makeClient { request in request.url?.path.hasSuffix("/reviews") == true ? (200, Data("[]".utf8)) : handler(request) }
    }

    /// One status read carries the request, its head, its approvals and its pipeline word, each from its own endpoint.
    @Test func aStatusReadsThePullItsApprovalsAndItsChecks() async throws {
        let (client, stub) = makeClient { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/check-runs") { return (200, Data(Self.runs([("test", "completed", "success"), ("lint", "in_progress", nil)]).utf8)) }
            if path.hasSuffix("/status") { return (200, Data(Self.statuses([]).utf8)) }
            if path.hasSuffix("/reviews") {
                return (200, Data((Self.page(request) == 1 ? #"[{"user":{"login":"alice"},"state":"APPROVED"}]"# : "[]").utf8))
            }
            return (200, Data(Self.pull().utf8))
        }
        let status = try await client.status(of: 88)
        #expect(status.request.iid == 88 && status.request.sourceBranch == "feat/pluto-231" && status.request.state == "open")
        #expect(status.head == Self.head)
        #expect(status.approvedBy == ["alice"])
        #expect(status.pipeline == "pending")
        #expect(status.readiness == .waiting("its checks are running"))
        #expect(stub.requests.filter { $0.url?.path == "/repos/octocat/hello/pulls/88" }.count == 1)
    }

    /// Every fact comes from one fetch of the pull: a push that lands after it changes nothing in this status, and the
    /// checks are the ones of the head that fetch named.
    @Test func everyFactOfAStatusComesFromOneFetchOfThePull() async throws {
        let moved = "b".padding(toLength: 40, withPad: "b", startingAt: 0)
        let fetches = Mutex(0)
        let checks = host(pull: "")
        let (client, stub) = statusClient { request in
            guard request.url?.path.hasSuffix("/pulls/88") == true else { return checks(request) }
            let first = fetches.withLock { $0 += 1; return $0 == 1 }
            return (200, Data((first ? Self.pull() : Self.pull().replacingOccurrences(of: Self.head, with: moved)).utf8))
        }
        let status = try await client.status(of: 88)
        #expect(status.head == Self.head)
        #expect(status.readiness == .ready(head: Self.head))
        let lists = stub.requests.compactMap(\.url?.path).filter { $0.hasSuffix("/check-runs") || $0.hasSuffix("/status") }
        #expect(lists.sorted() == ["/repos/octocat/hello/commits/\(Self.head)/check-runs", "/repos/octocat/hello/commits/\(Self.head)/status"])
        #expect(stub.requests.filter { $0.url?.path == "/repos/octocat/hello/pulls/88" }.count == 1)
    }

    /// A merged or closed pull's checks decide nothing, so they are not read; its approvals still are, for a signal
    /// done once it is approved.
    @Test func aMergedPullsStatusReadsItsApprovalsButNoChecks() async throws {
        let (client, stub) = makeClient { request in
            if request.url?.path.hasSuffix("/reviews") == true {
                return (200, Data((Self.page(request) == 1 ? #"[{"user":{"login":"alice"},"state":"APPROVED"}]"# : "[]").utf8))
            }
            return (200, Data(Self.pull(state: "closed", merged: true).utf8))
        }
        let status = try await client.status(of: 88)
        #expect(status.readiness == .merged(commit: Self.mergeCommit, head: Self.head, target: "main"))
        #expect(status.request.state == "merged" && status.approvedBy == ["alice"] && status.pipeline == nil)
        #expect(!stub.requests.contains { $0.url?.path.contains("/commits/") == true })
    }

    @Test func aFailingCheckOnALaterPageIsStillSeen() async throws {
        let first = (1...100).map { (name: "job-\($0)", status: "completed", conclusion: Optional("success")) }
        let (client, stub) = statusClient { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/check-runs") {
                return (200, Data((Self.page(request) == 1 ? Self.runs(first, total: 101)
                                   : Self.runs([("deploy", "completed", "failure")], total: 101)).utf8))
            }
            if path.hasSuffix("/status") { return (200, Data(Self.statuses([]).utf8)) }
            return (200, Data(Self.pull().utf8))
        }
        #expect(try await client.status(of: 88).readiness == .blocked("its check deploy failed"))
        #expect(stub.requests.filter { $0.url?.path.hasSuffix("/check-runs") == true }.count == 2)
    }

    @Test func statusesAreReadToTheEndToo() async throws {
        let all = (1...100).map { (context: "ci/\($0)", state: "success") }
        let (client, _) = statusClient { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/check-runs") { return (200, Data(Self.green.utf8)) }
            if path.hasSuffix("/status") {
                let first = Self.page(request) == 1
                let body = first ? Self.statuses(all) : Self.statuses([("ci/last", "failure")])
                return (200, Data(body.replacingOccurrences(of: #""total_count":\#(first ? 100 : 1)"#, with: #""total_count":101"#).utf8))
            }
            return (200, Data(Self.pull().utf8))
        }
        #expect(try await client.status(of: 88).readiness == .blocked("its status ci/last failed"))
    }

    /// A list that never reaches its total, or ends short of it, is not read whole: it waits, with no pipeline word.
    @Test func checksThatCannotBeReadWholeNeverReadReady() async throws {
        let endless = statusClient { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/check-runs") { return (200, Data(Self.runs([("test", "completed", "success")], total: 100_000).utf8)) }
            if path.hasSuffix("/status") { return (200, Data(Self.statuses([]).utf8)) }
            return (200, Data(Self.pull().utf8))
        }
        let unread = try await endless.client.status(of: 88)
        #expect(unread.readiness == .waiting("GitHub has not listed all its checks") && unread.pipeline == nil)
        #expect(endless.stub.requests.filter { $0.url?.path.hasSuffix("/check-runs") == true }.count == GitHubClient.listedPages,
                "it gives up after the pages it reads")
        #expect(endless.stub.requests.filter { $0.url?.path.hasSuffix("/status") == true }.count == 1)
        let short = statusClient(host(pull: Self.pull(), checkRuns: Self.runs([], total: 3)))
        #expect(try await short.client.status(of: 88).readiness == .waiting("GitHub has not listed all its checks"))
    }

    @Test func readinessThatCannotBeAskedThrows() async throws {
        for status in [401, 403, 404, 500] {
            await #expect(throws: GitHubError.self) {
                _ = try await self.makeClient { _ in (status, Data()) }.client.status(of: 88)
            }
        }
        await #expect(throws: GitHubError.decoding) {
            _ = try await self.statusClient(self.host(pull: Self.pull(), checkRuns: #"{"check_runs":[]}"#)).client.status(of: 88)
        }
        await #expect(throws: GitHubError.forbidden) {
            _ = try await self.statusClient { request in
                request.url?.path.hasSuffix("/status") == true ? (403, Data()) : (200, Data((request.url?.path.hasSuffix("/check-runs") == true ? Self.green : Self.pull()).utf8))
            }.client.status(of: 88)
        }
        let answers = host(pull: Self.pull())
        await #expect(throws: GitHubError.badResponse(502), "a status is never partial: approvals that fail fail it") {
            _ = try await self.makeClient { request in
                request.url?.path.hasSuffix("/reviews") == true ? (502, Data()) : answers(request)
            }.client.status(of: 88)
        }
    }

    // MARK: Merging

    @Test func itIsMergedAtTheAcceptedCommit() async throws {
        let answer = #"{"sha":"\#(Self.mergeCommit)","merged":true,"message":"Pull Request successfully merged"}"#
        let (client, stub) = makeClient { _ in (200, Data(answer.utf8)) }
        #expect(try await client.merge(88, at: Self.head) == .merged(commit: Self.mergeCommit, head: Self.head))
        let sent = try #require(stub.lastRequest)
        #expect(sent.httpMethod == "PUT")
        #expect(sent.url?.absoluteString == Self.api + "/pulls/88/merge")
        #expect(try body(sent) as NSDictionary == ["sha": Self.head], "only the accepted commit: no merge_method, no auto-merge, no title")
    }

    @Test func anAnswerThatDoesNotSayItMergedIsNotAMerge() async throws {
        for answer in [#"{"merged":false,"message":"queued"}"#, #"{"merged":true}"#, "{}"] {
            let (client, _) = makeClient { _ in (200, Data(answer.utf8)) }
            #expect(try await client.merge(88, at: Self.head) == .waiting("GitHub has not finished merging it"), "\(answer)")
        }
    }

    @Test func aRefusedMergeIsBlockedNotThrown() async throws {
        let (moved, _) = makeClient { _ in (409, Data(#"{"message":"Head branch was modified. Review and try the merge again."}"#.utf8)) }
        #expect(try await moved.merge(88, at: Self.head) == .blocked("the branch moved past the accepted commit"))
        for status in [405, 422] {
            let (client, _) = makeClient { _ in (status, Data(#"{"message":"Pull Request is not mergeable"}"#.utf8)) }
            #expect(try await client.merge(88, at: Self.head) == .blocked("GitHub refused to merge it (HTTP \(status))"))
        }
        await #expect(throws: GitHubError.unauthorized) {
            _ = try await self.makeClient { _ in (401, Data()) }.client.merge(88, at: Self.head)
        }
        await #expect(throws: GitHubError.badResponse(502)) {
            _ = try await self.makeClient { _ in (502, Data()) }.client.merge(88, at: Self.head)
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
        #expect(try await byRuleset.protection(of: "feat/pluto-231") == .protected("a ruleset’s pull request rule covers it"))
        #expect(stub.requests.first?.url?.absoluteString.hasPrefix(Self.api + "/rules/branches/feat%2Fpluto-231?") == true,
                "a slash in the branch stays inside its path segment")

        let classic = (200, Self.branch(protected: true))
        #expect(try await makeClient(protectionHost(branch: classic)).client.protection(of: "feat/pluto-231")
                == .protected("GitHub’s branch protection covers it"))

        let pattern = Self.rules(["feat/*"])
        #expect(try await makeClient(protectionHost(patterns: pattern)).client.protection(of: "feat/pluto-231")
                == .protected("the branch protection rule feat/* covers it"))
        #expect(try await makeClient(protectionHost(patterns: pattern)).client.protection(of: "feat/pluto/231")
                == .unprotected, "GitHub's * stops at a slash")
        #expect(try await makeClient(protectionHost(branch: classic)).client.protection(of: "refs/heads/feat/pluto-231")
                == .protected("GitHub’s branch protection covers it"), "a full ref names the same branch")
    }

    @Test func aRulesetRuleOtherThanAHarmlessOneProtects() async throws {
        let named = ["update", "creation", "pull_request", "required_status_checks", "required_deployments", "merge_queue",
                     "workflows", "code_scanning"]
        // A type GitHub has not announced yet is protection too, never harmless by default.
        for type in named + ["a_rule_from_the_future"] {
            let rule = #"[{"type":"\#(type)","ruleset_source_type":"Organization","ruleset_source":"octocat","ruleset_id":1}]"#
            let (client, _) = makeClient(protectionHost(rulesets: rule, branch: (200, Self.branch(protected: false, name: "feat/x"))))
            #expect(try await client.protection(of: "feat/x")
                    == .protected("a ruleset’s \(type.replacingOccurrences(of: "_", with: " ")) rule covers it"), "\(type)")
        }
        // One harmless rule beside a protective one does not hide it.
        let both = #"[{"type":"deletion"},{"type":"workflows"}]"#
        #expect(try await makeClient(protectionHost(rulesets: both)).client.protection(of: "feat/x")
                == .protected("a ruleset’s workflows rule covers it"))
    }

    @Test func everyHarmlessRulesetRuleLeavesTheBranchToTheOtherSources() async throws {
        for type in GitHubClient.harmlessRules {
            let rule = #"[{"type":"\#(type)","ruleset_source_type":"Organization","ruleset_source":"octocat","ruleset_id":1}]"#
            let (client, _) = makeClient(protectionHost(rulesets: rule, branch: (200, Self.branch(protected: false, name: "feat/x"))))
            #expect(try await client.protection(of: "feat/x") == .unprotected, "\(type)")
        }
        #expect(GitHubClient.harmlessRules.count == 12)
    }

    @Test func aBranchThatWasRenamedIsNotAnsweredForByItsNewNamesFlag() async throws {
        let (client, _) = makeClient(protectionHost(branch: (200, Self.branch(protected: false, name: "feat/renamed"))))
        await #expect(throws: ProtectionUnknown.self) {
            _ = try await client.protection(of: "feat/old")
        }
    }

    @Test func aPlusInABranchIsSentAsAPlus() async throws {
        let (client, stub) = makeClient { _ in (200, Data("[]".utf8)) }
        #expect(try await client.existingRequest(from: "feat/a+b") == nil)
        let url = try #require(stub.lastRequest?.url?.absoluteString)
        #expect(url.contains("head=octocat:feat/a%2Bb"))
        #expect(!url.contains("+"))
    }

    @Test func aRuleThatOnlyForbidsForcePushesProtectsNothingAiTermDoes() async throws {
        let noForce = #"[{"type":"non_fast_forward","ruleset_source_type":"Organization","ruleset_source":"octocat","ruleset_id":1},{"type":"deletion","ruleset_source_type":"Organization","ruleset_source":"octocat","ruleset_id":1}]"#
        let unprotected = (200, Self.branch(protected: false))
        #expect(try await makeClient(protectionHost(rulesets: noForce, branch: unprotected)).client
                .protection(of: "feat/pluto-231") == .unprotected)
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
        #expect(try await client.protection(of: "feat/x") == .protected("a ruleset’s required status checks rule covers it"))
        #expect(stub.requests.count == 2)
        let endless = makeClient { _ in (200, Data(#"[{"type":"deletion"}]"#.utf8)) }
        await #expect(throws: ProtectionUnknown.tooManyRules(GitHubClient.listedPages * 100)) {
            _ = try await endless.client.protection(of: "feat/x")
        }
        #expect(endless.stub.requests.count == GitHubClient.listedPages)
    }

    @Test func aBranchGitHubDoesNotHaveYetIsAskedByItsRulesPatterns() async throws {
        let (client, stub) = makeClient(protectionHost(patterns: Self.rules(["release/*", "main"])))
        #expect(try await client.protection(of: "feat/a b") == .unprotected)
        let urls = stub.requests.compactMap { $0.url?.absoluteString }
        #expect(urls.contains { $0.hasPrefix(Self.api + "/branches/feat%2Fa%20b") }, "a branch is asked for in one segment")
        #expect(urls.last == "https://api.github.com/graphql")
        // An existing branch is answered by its own flag: no pattern is read for it.
        let (existing, existingStub) = makeClient(protectionHost(branch: (200, Self.branch(protected: false))))
        #expect(try await existing.protection(of: "feat/pluto-231") == .unprotected)
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
        #expect(try await client.protection(of: "feat/x") == .protected("the branch protection rule feat/* covers it"))
        #expect(stub.requests.filter { $0.url?.path == "/graphql" }.count == 2)
        let endless = makeClient(protectionHost(patterns: Self.rules(["a"], next: "more")))
        await #expect(throws: ProtectionUnknown.self) {
            _ = try await endless.client.protection(of: "feat/x")
        }
        let stuck = makeClient(protectionHost(patterns: Self.rules(["a"], next: "same")))
        await #expect(throws: ProtectionUnknown.self) {
            _ = try await stuck.client.protection(of: "feat/x")
        }
        #expect(stuck.stub.requests.filter { $0.url?.path == "/graphql" }.count == 2, "a cursor that repeats stops it")
    }

    @Test func aPatternAiTermCannotReadIsNoAnswerUnlessAnotherRuleCoversTheBranch() async throws {
        let (client, _) = makeClient(protectionHost(patterns: Self.rules(["[z-a]", "feat/other"])))
        await #expect(throws: ProtectionUnknown.unreadable("AiTerm cannot read the branch pattern [z-a]")) {
            _ = try await client.protection(of: "feat/x")
        }
        let (covered, _) = makeClient(protectionHost(patterns: Self.rules(["[z-a]", "feat/*"])))
        #expect(try await covered.protection(of: "feat/x") == .protected("the branch protection rule feat/* covers it"))
    }

    /// What cannot be read is no answer: the caller pushes nothing.
    @Test func protectionThatCannotBeReadThrows() async throws {
        let hidden = #"{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository"}]}"#
        await #expect(throws: ProtectionUnknown.self) {
            _ = try await self.makeClient(self.protectionHost(patterns: hidden)).client.protection(of: "feat/x")
        }
        let partial = #"{"data":{"repository":{"branchProtectionRules":{"pageInfo":{"hasNextPage":false},"nodes":[]}}},"errors":[{"message":"Something went wrong"}]}"#
        await #expect(throws: ProtectionUnknown.self) {
            _ = try await self.makeClient(self.protectionHost(patterns: partial)).client.protection(of: "feat/x")
        }
        for repo in ["octocat", "octocat/hello/more", "/hello", ""] {
            await #expect(throws: ProtectionUnknown.self) {
                _ = try await self.makeClient(repo: repo, self.protectionHost()).client.protection(of: "feat/x")
            }
        }
        await #expect(throws: ProtectionUnknown.self) {
            _ = try await self.makeClient(self.protectionHost()).client.protection(of: "")
        }
    }

    /// Each source, failing on its own, with every status that is not an answer, and with an answer that is
    /// not what was asked for: `ProtectionUnknown`, never `.unprotected`.
    @Test func everySourceThatFailsLeavesProtectionUnknown() async throws {
        for source in ["rulesets", "branch", "graphql"] {
            for status in [401, 403, 404, 429, 500, 502] where !(source == "branch" && status == 404) {
                await #expect(throws: ProtectionUnknown.self, "\(source) \(status)") {
                    _ = try await self.makeClient(self.protectionHost(fail: [source: status])).client
                        .protection(of: "feat/x")
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
                _ = try await self.makeClient(handler).client.protection(of: "feat/x")
            }
        }
        // The same sources, each answering as it does for a branch that is not protected, are unprotected.
        #expect(try await makeClient(protectionHost()).client.protection(of: "feat/x") == .unprotected)
        #expect(try await makeClient(protectionHost(branch: (200, Self.branch(protected: false, name: "feat/x")))).client
                .protection(of: "feat/x") == .unprotected)
    }
}
