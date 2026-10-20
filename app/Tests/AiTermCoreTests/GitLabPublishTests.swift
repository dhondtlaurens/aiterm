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
            ("merged", "success", "not_open", .merged(commit: Self.mergeCommit, head: Self.head, target: "main")),
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
        #expect(try await client.merge(project: "web/acme-web", iid: 12, sha: Self.head) == .merged(commit: Self.mergeCommit, head: Self.head, target: "main"))
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

    /// GET /projects/:id, trimmed to the namespace that says whose rules also apply.
    static func project(kind: String = "group", fullPath: String = "web") -> String {
        #"{"id":42,"name":"acme-web","path_with_namespace":"web/acme-web","namespace":{"id":3,"name":"Web","path":"web","kind":"\#(kind)","full_path":"\#(fullPath)","parent_id":null}}"#
    }

    typealias Answer = (status: Int, body: Data)
    static func json(_ text: String, status: Int = 200) -> Answer { (status, Data(text.utf8)) }
    static func rules(_ names: [String]) -> Answer {
        json("[" + names.enumerated().map { #"{"id":\#($0.offset + 1),"name":"\#($0.element)"}"# }.joined(separator: ",") + "]")
    }
    /// `names` cut into pages of `size`, as a server that honours `page` and caps `per_page` there; an empty page past the end.
    static func paged(_ names: [String], size: Int) -> @Sendable (Int) -> Answer {
        { page in rules(Array(names.dropFirst((page - 1) * size).prefix(size))) }
    }
    static func page(of request: URLRequest) -> Int {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value.flatMap(Int.init) ?? 1
    }

    /// A GitLab that answers each of what AiTerm asks before a push: the project (its namespace), the project's rules,
    /// its group's rules and the branch itself. By default: a project in the group `web`, no rules, no group rules
    /// (404, as a group without any answers) and a branch GitLab does not have yet (404).
    private func protectionClient(project: Answer = json(project()), rules: @escaping @Sendable (Int) -> Answer = { _ in json("[]") },
                                  group: @escaping @Sendable (Int) -> Answer = { _ in json("{}", status: 404) },
                                  branch: Answer = json("{}", status: 404)) -> (client: GitLabClient, stub: StubSession) {
        makeClient { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/repository/branches/") { return branch }
            if url.contains("/api/v4/groups/") { return group(Self.page(of: request)) }
            if url.contains("/protected_branches") { return rules(Self.page(of: request)) }
            return project
        }
    }

    private func protection(_ branch: String, _ client: GitLabClient) async throws -> BranchProtection {
        try await client.branchProtection(project: "web/acme-web", branch: branch)
    }

    @Test func aBranchGitLabProtectsByNameOrWildcardIsSaid() async throws {
        let (client, stub) = protectionClient(rules: { page in page == 1 ? Self.json(Self.protected) : Self.json("[]") })
        #expect(try await protection("release/2026.10", client) == .protected("GitLab protects release/*"))
        #expect(try await protection("main", client) == .protected("GitLab protects it"))
        #expect(try await protection("feat/pluto-231-add-gift-card", client) == .unprotected)
        let listing = try #require(stub.requests.first { $0.url?.absoluteString.contains("/projects/web%2Facme-web/protected_branches") == true })
        #expect(listing.url?.absoluteString.hasPrefix("https://git.example.net/api/v4/projects/web%2Facme-web/protected_branches?") == true)
        #expect(listing.url?.absoluteString.contains("per_page=100") == true)
        #expect(listing.httpMethod == "GET")
        #expect(listing.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "tok")
    }

    @Test func everyPageOfProtectedBranchesIsReadUntilAnEmptyOne() async throws {
        let full = (1...100).map { "keep/\($0)" }
        let (client, stub) = protectionClient(rules: { page in
            switch page {
            case 1: Self.rules(full)
            case 2: Self.rules(["hotfix/*"])
            default: Self.json("[]")
            }
        })
        #expect(try await protection("hotfix/login", client) == .protected("GitLab protects hotfix/*"))
        #expect(stub.requests.filter { $0.url?.absoluteString.contains("/projects/web%2Facme-web/protected_branches") == true }.count == 3)
    }

    /// What cannot be read is no answer: the caller pushes nothing.
    @Test func protectionThatCannotBeReadThrows() async throws {
        await #expect(throws: GitLabError.unauthorized) {
            _ = try await self.makeClient { _ in (403, Data()) }.client.branchProtection(project: "web/acme-web", branch: "feat/x")
        }
        let full = Self.rules((1...100).map { "keep/\($0)" })
        await #expect(throws: ProtectionUnknown.tooManyRules(GitLabClient.protectedPages * 100)) {
            _ = try await self.protectionClient(rules: { _ in full }).client.branchProtection(project: "web/acme-web", branch: "feat/x")
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
        #expect(try await client.merge(project: "web/acme-web", iid: 12, sha: Self.head) == .merged(commit: Self.head, head: Self.head))
    }

    @Test func aDraftIsNeverReady() async throws {
        let draft = Self.status(detailed: "mergeable", pipeline: "success").replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#)
        let (client, _) = makeClient { _ in (200, Data(draft.utf8)) }
        #expect(try await client.mergeReadiness(project: "web/acme-web", iid: 12) == .blocked("it is a draft"))
    }

    /// Many CIs skip the pipeline of a draft: skipped is no failure while it is one, so the draft is all that stops it and
    /// it is marked ready. Not a draft, a skipped pipeline still blocks; a draft with conflicts says so.
    @Test func aDraftsSkippedPipelineLeavesTheDraftAsItsOnlyBlocker() async throws {
        func readiness(_ json: String) async throws -> MergeReadiness {
            let (client, _) = makeClient { _ in (200, Data(json.utf8)) }
            return try await client.mergeReadiness(project: "web/acme-web", iid: 12)
        }
        let draft = { (json: String) in json.replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#) }
        #expect(try await readiness(draft(Self.status(detailed: "draft_status", pipeline: "skipped"))) == .blocked("it is a draft"))
        #expect(try await readiness(Self.status(detailed: "mergeable", pipeline: "skipped")) == .blocked("the pipeline was skipped"))
        let conflicted = draft(Self.status(detailed: "draft_status", pipeline: "skipped"))
            .replacingOccurrences(of: #""has_conflicts":false"#, with: #""has_conflicts":true"#)
        #expect(try await readiness(conflicted) == .blocked("it has conflicts"))
    }

    /// A draft's pipeline is read first: what else stops it is said before the draft.
    @Test func aDraftsPipelineIsSaidBeforeTheDraft() async throws {
        let draft = Self.status(detailed: "draft_status", pipeline: "failed").replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#)
        let (client, _) = makeClient { _ in (200, Data(draft.utf8)) }
        #expect(try await client.mergeReadiness(project: "web/acme-web", iid: 12) == .blocked("its pipeline failed"))
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

    @Test func aShortPageProvesNothingAboutThePagesAfterIt() async throws {
        // A server that caps per_page at 20 (a proxy, a newer default): the covering rule is on page 3.
        let names = (1...45).map { "keep/\($0)" } + ["hotfix/*"]
        let (client, stub) = protectionClient(rules: Self.paged(names, size: 20))
        #expect(try await protection("hotfix/login", client) == .protected("GitLab protects hotfix/*"))
        #expect(stub.requests.filter { Self.page(of: $0) == 3 }.isEmpty == false)
        let (none, _) = protectionClient(rules: Self.paged(names, size: 20))
        #expect(try await protection("feat/x", none) == .unprotected)
    }

    @Test func aServerThatIgnoresThePageIsNotTakenForTheWholeList() async throws {
        let (client, _) = protectionClient(rules: { _ in Self.rules(["a", "b", "c"]) })
        await #expect(throws: ProtectionUnknown.tooManyRules(GitLabClient.protectedPages * 100)) { _ = try await self.protection("feat/x", client) }
    }

    @Test func anUnreadableRuleListIsNoAnswer() async throws {
        for answer in [("<html>sign in</html>", 200), (#"{"message":"ok"}"#, 200), (#"[{"id":1}]"#, 200), (#"[{"id":1,"name":null}]"#, 200)] {
            let (client, _) = protectionClient(rules: { _ in Self.json(answer.0, status: answer.1) })
            await #expect(throws: GitLabError.decoding, "\(answer.0)") { _ = try await self.protection("feat/x", client) }
        }
        for status in [401, 404, 500, 502] {
            let (client, _) = protectionClient(rules: { _ in Self.json("{}", status: status) })
            await #expect(throws: GitLabError.self, "HTTP \(status)") { _ = try await self.protection("feat/x", client) }
        }
    }

    @Test func aLaterPageThatFailsIsNoAnswerEither() async throws {
        let full = Self.rules((1...100).map { "keep/\($0)" })
        let (client, _) = protectionClient(rules: { page in page == 2 ? Self.json("{}", status: 500) : full })
        await #expect(throws: GitLabError.badResponse(500)) { _ = try await self.protection("feat/x", client) }
    }

    @Test func aRuleAiTermCannotEvaluateIsNoAnswer() async throws {
        let (client, _) = protectionClient(rules: { page in page == 1 ? Self.rules(["keep/*", "v[z-a]*"]) : Self.json("[]") })
        await #expect(throws: ProtectionUnknown.unreadable("AiTerm cannot read the branch pattern v[z-a]*")) { _ = try await self.protection("feat/x", client) }
        // A rule that does cover the branch says so whatever else is in the list.
        let (covered, _) = protectionClient(rules: { page in page == 1 ? Self.rules(["v[z-a]*", "feat/*"]) : Self.json("[]") })
        #expect(try await protection("feat/x", covered) == .protected("GitLab protects feat/*"))
    }

    @Test func protectionIsCaseSensitiveAndSpellingProof() async throws {
        let (client, _) = protectionClient(rules: { page in page == 1 ? Self.rules(["main", "Release/*"]) : Self.json("[]") })
        #expect(try await protection("Main", client) == .unprotected, "GitLab compares names exactly")
        #expect(try await protection("release/1", client) == .unprotected)
        #expect(try await protection("Release/1", client) == .protected("GitLab protects Release/*"))
        #expect(try await protection("refs/heads/main", client) == .protected("GitLab protects it"))
        await #expect(throws: ProtectionUnknown.self) { _ = try await self.protection("", client) }
    }

    @Test func aWildcardSpansSlashesAndOnlyAWildcardDoes() async throws {
        let (client, _) = protectionClient(rules: { page in page == 1 ? Self.rules(["release/*", "prod-*", "a.b"]) : Self.json("[]") })
        #expect(try await protection("release/2026/10/rc", client) == .protected("GitLab protects release/*"))
        #expect(try await protection("prod-", client) == .protected("GitLab protects prod-*"))
        #expect(try await protection("axb", client) == .unprotected)
        #expect(try await protection("feat/release/1", client) == .unprotected)
    }

    // MARK: Group-level rules and the branch's own flag

    @Test func theTopLevelGroupsRulesProtectABranchToo() async throws {
        let (client, stub) = protectionClient(project: Self.json(Self.project(fullPath: "web/team/sub")),
                                              group: Self.paged(["feat/*"], size: 100))
        #expect(try await protection("feat/pluto-231", client) == .protected("GitLab group web protects feat/*"))
        let asked = stub.requests.compactMap { $0.url?.absoluteString }.first { $0.contains("/api/v4/groups/") }
        #expect(asked?.hasPrefix("https://git.example.net/api/v4/groups/web/protected_branches?") == true, "the root of web/team/sub")
    }

    @Test func aGroupWithNoRulesAnswers404AndProtectsNothing() async throws {
        let (client, _) = protectionClient()
        #expect(try await protection("feat/pluto-231", client) == .unprotected)
        let (empty, _) = protectionClient(group: { _ in Self.json("[]") })
        #expect(try await protection("feat/pluto-231", empty) == .unprotected)
    }

    @Test func groupRulesArePagedLikeTheProjectsAndCapped() async throws {
        let names = (1...45).map { "keep/\($0)" } + ["hotfix/*"]
        let (client, _) = protectionClient(group: Self.paged(names, size: 20))
        #expect(try await protection("hotfix/login", client) == .protected("GitLab group web protects hotfix/*"))
        let (endless, _) = protectionClient(group: { _ in Self.rules(["a"]) })
        await #expect(throws: ProtectionUnknown.tooManyRules(GitLabClient.protectedPages * 100)) { _ = try await self.protection("feat/x", endless) }
    }

    @Test func aGroupListingThatFailsOtherThanWith404IsNoAnswer() async throws {
        for status in [401, 403, 500, 502] {
            let (client, _) = protectionClient(group: { _ in Self.json("{}", status: status) })
            await #expect(throws: ProtectionUnknown.self, "HTTP \(status)") { _ = try await self.protection("feat/x", client) }
        }
        for body in ["<html>sign in</html>", #"{"message":"ok"}"#, #"[{"id":1}]"#] {
            let (client, _) = protectionClient(group: { _ in Self.json(body) })
            await #expect(throws: ProtectionUnknown.self, "\(body)") { _ = try await self.protection("feat/x", client) }
        }
        // A 404 after the first page is no "group without rules".
        let full = Self.rules((1...100).map { "keep/\($0)" })
        let (later, _) = protectionClient(group: { page in page == 1 ? full : Self.json("{}", status: 404) })
        await #expect(throws: ProtectionUnknown.self) { _ = try await self.protection("feat/x", later) }
        await #expect(throws: ProtectionUnknown.unreadable("AiTerm could not read the protected branches of the GitLab group web: Check your GitLab access token in Settings › Integrations")) {
            _ = try await self.protection("feat/x", self.protectionClient(group: { _ in Self.json("{}", status: 403) }).client)
        }
    }

    @Test func aProjectInAUsersNamespaceHasNoGroupToAsk() async throws {
        let (client, stub) = protectionClient(project: Self.json(Self.project(kind: "user", fullPath: "laurens")),
                                              group: { _ in Self.json("{}", status: 500) })
        #expect(try await protection("feat/x", client) == .unprotected)
        #expect(stub.requests.contains { $0.url?.absoluteString.contains("/api/v4/groups/") == true } == false)
    }

    @Test func aNamespaceGitLabDoesNotDescribeIsNoAnswer() async throws {
        for body in [Self.project(kind: "project", fullPath: "web"), Self.project(kind: "group", fullPath: ""),
                     #"{"id":42}"#, #"{"id":42,"namespace":{"kind":"group"}}"#] {
            let (client, _) = protectionClient(project: Self.json(body))
            await #expect(throws: ProtectionUnknown.self, "\(body)") { _ = try await self.protection("feat/x", client) }
        }
        for status in [401, 404, 500] {
            let (client, _) = protectionClient(project: Self.json("{}", status: status))
            await #expect(throws: GitLabError.self, "HTTP \(status)") { _ = try await self.protection("feat/x", client) }
        }
    }

    @Test func aBranchGitLabAlreadyHasAndCallsProtectedIsProtected() async throws {
        let (client, stub) = protectionClient(branch: Self.json(#"{"name":"feat/x","protected":true,"default":false,"commit":{"id":"\#(Self.head)"}}"#))
        #expect(try await protection("feat/x", client) == .protected("GitLab protects it"))
        let asked = stub.requests.compactMap { $0.url?.absoluteString }.first { $0.contains("/repository/branches/") }
        #expect(asked == "https://git.example.net/api/v4/projects/web%2Facme-web/repository/branches/feat%2Fx", "the branch is one path segment")
        let (open, _) = protectionClient(branch: Self.json(#"{"name":"feat/x","protected":false}"#))
        #expect(try await protection("feat/x", open) == .unprotected)
        let (notThere, _) = protectionClient(branch: Self.json("{}", status: 404))
        #expect(try await protection("feat/x", notThere) == .unprotected, "a 404 is a branch GitLab does not have yet")
    }

    @Test func aBranchAnswerThatIsNotAnAnswerIsNoAnswer() async throws {
        for answer in [Self.json("{}", status: 500), Self.json("{}", status: 403), Self.json("<html></html>"), Self.json(#"{"name":"feat/x"}"#)] {
            let (client, _) = protectionClient(branch: answer)
            await #expect(throws: (any Error).self, "\(answer.status) \(String(decoding: answer.body, as: UTF8.self))") { _ = try await self.protection("feat/x", client) }
        }
    }

    @Test func anUnreadablePatternStillStopsABranchTheFlagWouldClear() async throws {
        let (client, _) = protectionClient(rules: { page in page == 1 ? Self.rules(["v[z-a]*"]) : Self.json("[]") },
                                           branch: Self.json(#"{"name":"feat/x","protected":false}"#))
        await #expect(throws: ProtectionUnknown.self) { _ = try await self.protection("feat/x", client) }
    }

    // MARK: Open requests and pipelines

    @Test func theOpenRequestCarriesItsTargetForTheCallerToCheck() async throws {
        let toRelease = Self.status(detailed: "mergeable", pipeline: "success").replacingOccurrences(of: #""target_branch":"main""#, with: #""target_branch":"release/1.0""#)
        let toMain = Self.status(detailed: "mergeable", pipeline: "success").replacingOccurrences(of: #""iid":12"#, with: #""iid":13"#)
        let (client, _) = makeClient { _ in (200, Data("[\(toRelease),\(toMain)]".utf8)) }
        let found = try #require(try await client.openMergeRequest(project: "web/acme-web", source: "feat/pluto-231-add-gift-card"))
        #expect(found.iid == 12 && found.targetBranch == "release/1.0" && found.sourceBranch == "feat/pluto-231-add-gift-card")
    }

    @Test func aPipelineThatDidNotRunIsNotGreen() async throws {
        let cases: [(pipeline: String, expected: MergeReadiness)] = [
            ("manual", .blocked("the pipeline waits for a manual job")),
            ("skipped", .blocked("the pipeline was skipped")),
        ]
        for item in cases {
            let answer = Self.status(detailed: "mergeable", pipeline: item.pipeline)
            let (client, _) = makeClient { _ in (200, Data(answer.utf8)) }
            #expect(try await client.mergeReadiness(project: "web/acme-web", iid: 12) == item.expected, "\(item.pipeline)")
        }
    }
}
