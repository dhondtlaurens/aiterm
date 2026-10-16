import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// GitLab's write calls for finish_task, against response bodies recorded from GitLab's REST API
/// (v4, as GitLab 17 answers), trimmed to the fields AiTerm reads plus a few it does not.
@Suite struct GitLabPublishTests {
    let config = GitLabConfig(hostURL: URL(string: "https://git.example.net")!, token: "tok")
    static let head = "4f2a91c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6"
    static let mergeCommit = "9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d"
    static let base = "https://git.example.net/api/v4/projects/web%2Facme-web/merge_requests"

    static let created = """
        {"id":9001,"iid":12,"project_id":42,"title":"Draft: PLUTO-231 Add gift card","description":"Opened by AiTerm",
         "state":"opened","created_at":"2026-10-16T08:00:00.000Z","target_branch":"main",
         "source_branch":"feat/pluto-231-add-gift-card","author":{"id":7,"name":"Laurens","username":"laurens"},
         "draft":true,"work_in_progress":true,"merge_when_pipeline_succeeds":false,"detailed_merge_status":"draft_status",
         "sha":"\(head)","merge_commit_sha":null,"squash_commit_sha":null,"head_pipeline":null,
         "web_url":"https://git.example.net/web/acme-web/-/merge_requests/12"}
        """

    /// GET /projects/:id/merge_requests/:iid as GitLab answers it in each state AiTerm reads.
    static func status(state: String = "opened", detailed: String, pipeline: String?) -> String {
        let pipelineJSON = pipeline.map { #"{"id":5501,"sha":"\#(head)","ref":"feat/pluto-231-add-gift-card","status":"\#($0)"}"# } ?? "null"
        let merged = state == "merged" ? "\"\(mergeCommit)\"" : "null"
        return """
            {"id":9001,"iid":12,"project_id":42,"title":"PLUTO-231 Add gift card","state":"\(state)","draft":false,
             "target_branch":"main","source_branch":"feat/pluto-231-add-gift-card","author":{"name":"Laurens"},
             "detailed_merge_status":"\(detailed)","has_conflicts":\(detailed == "conflict"),"sha":"\(head)",
             "merge_commit_sha":\(merged),"squash_commit_sha":null,"head_pipeline":\(pipelineJSON),
             "web_url":"https://git.example.net/web/acme-web/-/merge_requests/12"}
            """
    }

    private func makeClient(_ handler: @escaping StubURLProtocol.Handler) -> (client: GitLabClient, stub: StubSession) {
        let stub = StubSession(handler: handler)
        return (GitLabClient(config: config, session: stub.session), stub)
    }

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func aDraftIsOpenedFromTheTasksBranch() async throws {
        let (client, stub) = makeClient { _ in (201, Data(Self.created.utf8)) }
        let request = try await client.createMergeRequest(project: "web/acme-web", source: "feat/pluto-231-add-gift-card",
                                                          target: "main", title: "PLUTO-231 Add gift card",
                                                          description: "Opened by AiTerm", draft: true)
        #expect(request == MergeRequest(iid: 12, title: "Draft: PLUTO-231 Add gift card", sourceBranch: "feat/pluto-231-add-gift-card",
                                        targetBranch: "main", author: "Laurens", state: "opened", draft: true,
                                        url: "https://git.example.net/web/acme-web/-/merge_requests/12"))
        let sent = try #require(stub.lastRequest)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == Self.base)
        #expect(sent.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "tok")
        let fields = try body(sent)
        #expect(fields["source_branch"] as? String == "feat/pluto-231-add-gift-card")
        #expect(fields["target_branch"] as? String == "main")
        #expect(fields["title"] as? String == "Draft: PLUTO-231 Add gift card")
        #expect(fields["description"] as? String == "Opened by AiTerm")
        #expect(fields["remove_source_branch"] as? Bool == false, "deleting a branch is ask-first")
    }

    @Test func aMergeEndsRequestIsNoDraft() async throws {
        let (client, stub) = makeClient { _ in (201, Data(Self.created.utf8)) }
        _ = try await client.createMergeRequest(project: "web/acme-web", source: "feat/x", target: "main",
                                                title: "PLUTO-231 Add gift card", description: "", draft: false)
        #expect(try body(stub.lastRequest)["title"] as? String == "PLUTO-231 Add gift card")
    }

    @Test func theOpenRequestFromABranchIsFoundNotOpenedAgain() async throws {
        let list = "[" + Self.status(detailed: "mergeable", pipeline: "success") + "]"
        let (client, stub) = makeClient { _ in (200, Data(list.utf8)) }
        #expect(try await client.openMergeRequest(project: "web/acme-web", source: "feat/pluto-231-add-gift-card")?.iid == 12)
        let url = try #require(stub.lastRequest?.url?.absoluteString)
        #expect(url.hasPrefix(Self.base + "?"))
        #expect(url.contains("state=opened"))
        #expect(url.contains("source_branch=feat/pluto-231-add-gift-card"))
        let (none, _) = makeClient { _ in (200, Data("[]".utf8)) }
        #expect(try await none.openMergeRequest(project: "web/acme-web", source: "feat/x") == nil)
    }

    @Test func readinessIsGitLabsOwnVerdictWithItsPipeline() async throws {
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
            ("merged", "success", "not_open", .merged(commit: Self.mergeCommit)),
            ("closed", nil, "not_open", .blocked("the merge request is closed")),
        ]
        for item in cases {
            let answer = Self.status(state: item.state, detailed: item.detailed, pipeline: item.pipeline)
            let (client, stub) = makeClient { _ in (200, Data(answer.utf8)) }
            #expect(try await client.mergeReadiness(project: "web/acme-web", iid: 12) == item.expected,
                    "\(item.state) \(item.pipeline ?? "no pipeline") \(item.detailed)")
            #expect(stub.lastRequest?.url?.absoluteString == Self.base + "/12")
        }
    }

    @Test func itIsMergedAtTheAcceptedCommit() async throws {
        let answer = Self.status(state: "merged", detailed: "not_open", pipeline: "success")
        let (client, stub) = makeClient { _ in (200, Data(answer.utf8)) }
        #expect(try await client.merge(project: "web/acme-web", iid: 12, sha: Self.head) == .merged(commit: Self.mergeCommit))
        let sent = try #require(stub.lastRequest)
        #expect(sent.httpMethod == "PUT")
        #expect(sent.url?.absoluteString == Self.base + "/12/merge")
        #expect(try body(sent)["sha"] as? String == Self.head)
    }

    @Test func aRefusedMergeIsBlockedNotThrown() async throws {
        let refusal = Data(#"{"message":"SHA does not match HEAD of source branch"}"#.utf8)
        let (moved, _) = makeClient { _ in (409, refusal) }
        #expect(try await moved.merge(project: "web/acme-web", iid: 12, sha: Self.head) == .blocked("the branch moved past the accepted commit"))
        for status in [405, 406, 422] {
            let (client, _) = makeClient { _ in (status, Data(#"{"message":"Method Not Allowed"}"#.utf8)) }
            #expect(try await client.merge(project: "web/acme-web", iid: 12, sha: Self.head) == .blocked("GitLab refused to merge it (HTTP \(status))"))
        }
        await #expect(throws: GitLabError.unauthorized) {
            _ = try await self.makeClient { _ in (401, Data()) }.client.merge(project: "web/acme-web", iid: 12, sha: Self.head)
        }
    }

    @Test func aRequestIsRetargeted() async throws {
        let (client, stub) = makeClient { _ in (200, Data(Self.status(detailed: "mergeable", pipeline: "success").utf8)) }
        try await client.retarget(project: "web/acme-web", iid: 12, to: "main")
        let sent = try #require(stub.lastRequest)
        #expect(sent.httpMethod == "PUT")
        #expect(sent.url?.absoluteString == Self.base + "/12")
        #expect(try body(sent)["target_branch"] as? String == "main")
    }

    /// GET /projects/:id/protected_branches, as GitLab 17 answers it: a name or a `*` wildcard per rule.
    static let protected = """
        [{"id":1,"name":"main","push_access_levels":[{"id":1,"access_level":40,"access_level_description":"Maintainers"}],
          "merge_access_levels":[{"id":1,"access_level":40}],"allow_force_push":false,"code_owner_approval_required":false},
         {"id":2,"name":"release/*","push_access_levels":[],"merge_access_levels":[],"allow_force_push":false}]
        """

    @Test func aBranchGitLabProtectsByNameOrWildcardIsSaid() async throws {
        let (client, stub) = makeClient { _ in (200, Data(Self.protected.utf8)) }
        #expect(try await client.branchProtection(project: "web/acme-web", branch: "release/2026.10") == .protected("GitLab protects release/*"))
        #expect(try await client.branchProtection(project: "web/acme-web", branch: "main") == .protected("GitLab protects it"))
        #expect(try await client.branchProtection(project: "web/acme-web", branch: "feat/pluto-231-add-gift-card") == .unprotected)
        let url = try #require(stub.lastRequest?.url?.absoluteString)
        #expect(url.hasPrefix("https://git.example.net/api/v4/projects/web%2Facme-web/protected_branches?"))
        #expect(url.contains("per_page=100"))
        #expect(stub.lastRequest?.httpMethod == "GET")
    }

    @Test func everyPageOfProtectedBranchesIsRead() async throws {
        let full = "[" + (1...100).map { #"{"id":\#($0),"name":"keep/\#($0)"}"# }.joined(separator: ",") + "]"
        let (client, stub) = makeClient { request in
            request.url?.query?.contains("page=2") == true ? (200, Data(#"[{"id":101,"name":"hotfix/*"}]"#.utf8)) : (200, Data(full.utf8))
        }
        #expect(try await client.branchProtection(project: "web/acme-web", branch: "hotfix/login") == .protected("GitLab protects hotfix/*"))
        #expect(stub.requests.count == 2)
    }

    /// What cannot be read is no answer: the caller pushes nothing.
    @Test func protectionThatCannotBeReadThrows() async throws {
        await #expect(throws: GitLabError.unauthorized) {
            _ = try await self.makeClient { _ in (403, Data()) }.client.branchProtection(project: "web/acme-web", branch: "feat/x")
        }
        let full = "[" + (1...100).map { #"{"id":\#($0),"name":"keep/\#($0)"}"# }.joined(separator: ",") + "]"
        await #expect(throws: ProtectionUnknown.tooManyRules(GitLabClient.protectedPages * 100)) {
            _ = try await self.makeClient { _ in (200, Data(full.utf8)) }.client.branchProtection(project: "web/acme-web", branch: "feat/x")
        }
    }

    // MARK: Beyond the recorded happy path — what must hold when GitLab answers oddly

    private func fieldNames(_ request: URLRequest?) throws -> Set<String> { Set(try body(request).keys) }

    @Test func noWriteAsksGitLabToMergeSquashOrDeleteAnything() async throws {
        let (creator, created) = makeClient { _ in (201, Data(Self.created.utf8)) }
        _ = try await creator.createMergeRequest(project: "web/acme-web", source: "feat/x", target: "main", title: "T", description: "D", draft: false)
        #expect(try fieldNames(created.lastRequest) == ["source_branch", "target_branch", "title", "description", "remove_source_branch"])
        let merged = Self.status(state: "merged", detailed: "not_open", pipeline: "success")
        let (merger, merge) = makeClient { _ in (200, Data(merged.utf8)) }
        _ = try await merger.merge(project: "web/acme-web", iid: 12, sha: Self.head)
        #expect(try fieldNames(merge.lastRequest) == ["sha"], "no auto-merge, no squash, no source-branch removal")
        let (mover, move) = makeClient { _ in (200, Data(Self.status(detailed: "mergeable", pipeline: "success").utf8)) }
        try await mover.retarget(project: "web/acme-web", iid: 12, to: "main")
        #expect(try fieldNames(move.lastRequest) == ["target_branch"])
    }

    @Test func aMergeGitLabHasNotRunYetIsWaitingNotMerged() async throws {
        let open = Self.status(detailed: "mergeable", pipeline: "success")
        let (client, _) = makeClient { _ in (200, Data(open.utf8)) }
        #expect(try await client.merge(project: "web/acme-web", iid: 12, sha: Self.head) == .waiting("GitLab has not finished merging it"))
    }

    @Test func aFastForwardMergeIsTheAcceptedCommit() async throws {
        let answer = #"{"iid":12,"state":"merged","sha":"\#(Self.head)","merge_commit_sha":null,"squash_commit_sha":null}"#
        let (client, _) = makeClient { _ in (200, Data(answer.utf8)) }
        #expect(try await client.merge(project: "web/acme-web", iid: 12, sha: Self.head) == .merged(commit: Self.head))
    }

    @Test func aDraftIsNeverReady() async throws {
        let draft = Self.status(detailed: "mergeable", pipeline: "success").replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#)
        let (client, _) = makeClient { _ in (200, Data(draft.utf8)) }
        #expect(try await client.mergeReadiness(project: "web/acme-web", iid: 12) == .blocked("it is a draft"))
    }

    @Test func anUnknownPipelineStatusIsNotGreen() async throws {
        let (client, _) = makeClient { _ in (200, Data(Self.status(detailed: "mergeable", pipeline: "on_hold").utf8)) }
        #expect(try await client.mergeReadiness(project: "web/acme-web", iid: 12) == .waiting("its pipeline is on hold"))
    }

    @Test func aRequestThatCannotBeReadIsNotAnAbsentOne() async throws {
        // Reading it as "none" would open a second request for the branch.
        let (client, _) = makeClient { _ in (200, Data(#"[{"iid":12}]"#.utf8)) }
        await #expect(throws: GitLabError.decoding) {
            _ = try await client.openMergeRequest(project: "web/acme-web", source: "feat/x")
        }
    }

    @Test func aForksRequestFromABranchOfTheSameNameIsNotOurs() async throws {
        let fork = Self.status(detailed: "mergeable", pipeline: "success").replacingOccurrences(of: #""project_id":42"#, with: #""source_project_id":99,"target_project_id":42"#)
        let own = fork.replacingOccurrences(of: #""iid":12"#, with: #""iid":13"#).replacingOccurrences(of: "99", with: "42")
        let (client, _) = makeClient { _ in (200, Data("[\(fork),\(own)]".utf8)) }
        #expect(try await client.openMergeRequest(project: "web/acme-web", source: "feat/x")?.iid == 13)
        let (onlyFork, _) = makeClient { _ in (200, Data("[\(fork)]".utf8)) }
        #expect(try await onlyFork.openMergeRequest(project: "web/acme-web", source: "feat/x") == nil)
    }

    @Test func aBranchNameIsEscapedWhereAQueryWouldReadItAsSomethingElse() async throws {
        let (client, stub) = makeClient { _ in (200, Data("[]".utf8)) }
        _ = try await client.openMergeRequest(project: "web/acme-web", source: "feat/a+b&c=d")
        let query = try #require(stub.lastRequest?.url?.query)
        #expect(!query.contains("+") && !query.contains("&c") && query.contains("feat/a%2Bb%26c%3Dd"), "\(query)")
    }

    // MARK: Protection fails closed

    private func protectedList(_ names: [String]) -> Data {
        Data(("[" + names.enumerated().map { #"{"id":\#($0.offset + 1),"name":"\#($0.element)"}"# }.joined(separator: ",") + "]").utf8)
    }

    @Test func anUnreadableRuleListIsNoAnswer() async throws {
        for answer in [(200, "<html>sign in</html>"), (200, #"{"message":"ok"}"#), (200, #"[{"id":1}]"#), (200, #"[{"id":1,"name":null}]"#)] {
            let (client, _) = makeClient { _ in (answer.0, Data(answer.1.utf8)) }
            await #expect(throws: GitLabError.decoding, "\(answer.1)") {
                _ = try await client.branchProtection(project: "web/acme-web", branch: "feat/x")
            }
        }
        for status in [401, 404, 500, 502] {
            let (client, _) = makeClient { _ in (status, Data()) }
            await #expect(throws: GitLabError.self, "HTTP \(status)") {
                _ = try await client.branchProtection(project: "web/acme-web", branch: "feat/x")
            }
        }
    }

    @Test func aLaterPageThatFailsIsNoAnswerEither() async throws {
        let full = "[" + (1...100).map { #"{"id":\#($0),"name":"keep/\#($0)"}"# }.joined(separator: ",") + "]"
        let (client, _) = makeClient { request in
            request.url?.query?.contains("page=2") == true ? (500, Data()) : (200, Data(full.utf8))
        }
        await #expect(throws: GitLabError.badResponse(500)) {
            _ = try await client.branchProtection(project: "web/acme-web", branch: "feat/x")
        }
    }

    @Test func aRuleAiTermCannotEvaluateIsNoAnswer() async throws {
        let (client, _) = makeClient { _ in (200, self.protectedList(["keep/*", "v[z-a]*"])) }
        await #expect(throws: ProtectionUnknown.unreadable("AiTerm cannot read the branch pattern v[z-a]*")) {
            _ = try await client.branchProtection(project: "web/acme-web", branch: "feat/x")
        }
        // A rule that does cover the branch says so whatever else is in the list.
        let (covered, _) = makeClient { _ in (200, self.protectedList(["v[z-a]*", "feat/*"])) }
        #expect(try await covered.branchProtection(project: "web/acme-web", branch: "feat/x") == .protected("GitLab protects feat/*"))
    }

    @Test func protectionIsCaseSensitiveAndSpellingProof() async throws {
        let (client, _) = makeClient { _ in (200, self.protectedList(["main", "Release/*"])) }
        #expect(try await client.branchProtection(project: "web/acme-web", branch: "Main") == .unprotected, "GitLab compares names exactly")
        #expect(try await client.branchProtection(project: "web/acme-web", branch: "release/1") == .unprotected)
        #expect(try await client.branchProtection(project: "web/acme-web", branch: "Release/1") == .protected("GitLab protects Release/*"))
        #expect(try await client.branchProtection(project: "web/acme-web", branch: "refs/heads/main") == .protected("GitLab protects it"))
        await #expect(throws: ProtectionUnknown.self) { _ = try await client.branchProtection(project: "web/acme-web", branch: "") }
    }

    @Test func aWildcardSpansSlashesAndOnlyAWildcardDoes() async throws {
        let (client, _) = makeClient { _ in (200, self.protectedList(["release/*", "prod-*", "a.b"])) }
        #expect(try await client.branchProtection(project: "web/acme-web", branch: "release/2026/10/rc") == .protected("GitLab protects release/*"))
        #expect(try await client.branchProtection(project: "web/acme-web", branch: "prod-") == .protected("GitLab protects prod-*"))
        #expect(try await client.branchProtection(project: "web/acme-web", branch: "axb") == .unprotected)
        #expect(try await client.branchProtection(project: "web/acme-web", branch: "feat/release/1") == .unprotected)
    }
}

