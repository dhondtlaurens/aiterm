import Foundation
import Testing
import Synchronization
@testable import AiTermCore
@testable import AiTermTestSupport

/// Synthetic response recordings drawn from the Jira enhanced-search, GitLab global MR and
/// GitHub GraphQL search schemas on 14 Nov 2026. No account or live ticket is represented.
@Suite struct SignalSourceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let config = JiraConfig(siteURL: URL(string: "https://jira.example")!, email: "me@example.invalid", token: "test")

    @Test func jiraReaderPagesAndKeepsEveryFieldNeededForMatching() async throws {
        let stub = StubSession { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            if body?["nextPageToken"] as? String == "second" {
                return (200, Data(#"{"isLast":true,"issues":[{"key":"PAY-2","fields":{"summary":"Second"}}]}"#.utf8))
            }
            #expect(body?["maxResults"] as? Int == 100)
            return (200, Data(#"{"nextPageToken":"second","isLast":false,"issues":[{"key":"PAY-1","fields":{"summary":"First","description":"Details","labels":["agent"],"project":{"key":"PAY"},"assignee":{"accountId":"me"},"status":{"name":"Open"}}}]}"#.utf8))
        }
        let reader = JiraQueryReader(client: JiraClient(config: config, session: stub.session), conditions: JiraConditions(labels: ["agent"]), now: { now })
        let read = try await reader.poll(since: nil, full: true)
        #expect(read.complete && read.items.count == 2 && read.cursor == now)
        #expect(read.items[0].ticket?.labels == ["agent"] && read.items[0].ticket?.project == "PAY")
        #expect(read.items[0].ticket?.assignee == "me" && read.items[0].description == "Details")
        #expect(stub.requests.count == 2)
    }

    @Test func jiraMalformedEntryOrRepeatedCursorMakesTheWholeReadIncomplete() async throws {
        let stub = StubSession { _ in
            (200, Data(#"{"nextPageToken":"repeat","isLast":false,"issues":[{"key":"PAY-1","fields":{"summary":"Valid"}},{}]}"#.utf8))
        }
        let reader = JiraQueryReader(client: JiraClient(config: config, session: stub.session), conditions: JiraConditions(), now: { now })
        let read = try await reader.poll(since: nil, full: true)
        #expect(!read.complete && read.cursor == nil)
        #expect(stub.requests.count <= 2)
    }

    @Test func jiraRateLimitDoesNotReturnAnEmptyCompleteRead() async throws {
        let stub = StubSession { _ in (429, Data()) }
        let reader = JiraQueryReader(client: JiraClient(config: config, session: stub.session), conditions: JiraConditions(), now: { now })
        await #expect(throws: JiraError.badResponse(429)) { try await reader.poll(since: nil, full: true) }
    }

    @Test func gitLabAccountPagesHostWideAndScopesToTheReviewer() async throws {
        let stub = StubSession { request in
            if request.url?.path == "/api/v4/user" { return (200, Data(#"{"username":"me"}"#.utf8)) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(query.contains(URLQueryItem(name: "reviewer_username", value: "me")))
            #expect(query.contains(URLQueryItem(name: "scope", value: "all")))
            #expect(request.url?.path == "/api/v4/merge_requests")
            return (200, Data(#"[{"iid":7,"title":"Review","source_branch":"work","target_branch":"main","web_url":"https://git.example/shop/repo/-/merge_requests/7","author":{"username":"colleague"},"updated_at":"2026-11-14T12:00:00Z"}]"#.utf8))
        }
        let account = GitLabAccount(config: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "test"), session: stub.session)
        let read = try await HostUserMemo.$current.withValue(HostUserMemo.Cache()) { try await account.requests(event: .reviewRequested, since: nil) }
        #expect(read.complete && read.items.count == 1)
        #expect(read.items[0].item.identity == ItemRef.request(remote: "https://git.example/shop/repo", number: 7).identity)
    }

    @Test func gitHubPersonalReviewSearchUsesGraphQLAndFollowsItsCursor() async throws {
        let calls = Mutex(0)
        let stub = StubSession { request in
            #expect(request.url?.path == "/graphql")
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let variables = body?["variables"] as? [String: Any]
            #expect((variables?["query"] as? String)?.contains("user-review-requested:@me") == true)
            let next = calls.withLock { $0 += 1; return $0 }
            if next == 1 {
                return (200, Data(#"{"data":{"search":{"issueCount":1,"pageInfo":{"hasNextPage":true,"endCursor":"second"},"nodes":[{"number":7,"title":"Review","url":"https://github.com/shop/repo/pull/7","headRefName":"work","baseRefName":"main","isDraft":false,"body":"Details","author":{"login":"colleague"},"repository":{"nameWithOwner":"shop/repo"},"updatedAt":"2026-11-14T12:00:00Z"}]}}}"#.utf8))
            }
            #expect(variables?["cursor"] as? String == "second")
            return (200, Data(#"{"data":{"search":{"issueCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}"#.utf8))
        }
        let account = GitHubAccount(config: GitHubConfig(token: "test"), session: stub.session)
        let read = try await HostUserMemo.$current.withValue(HostUserMemo.Cache()) { try await account.requests(event: .reviewRequested, since: nil) }
        #expect(read.complete && read.items.count == 1 && stub.requests.count == 2)
        #expect(read.items[0].mergeRequest?.sourceBranch == "work")
    }

    @Test func projectMapperReportsNoneOneAndSeveralWithoutCloning() {
        let ticket = ItemRef.ticket(site: "https://jira.example", key: "PAY-1")
        let link = JiraProjectRef(id: "1", key: "PAY", name: "Payments", siteURL: config.siteURL)
        let a = Project.make(jiraProjects: [link]), b = Project.make(jiraProjects: [link])
        #expect(ItemProjectMapper.projects(for: ticket, in: []).isEmpty)
        #expect(ItemProjectMapper.projects(for: ticket, in: [a]).map(\.id) == [a.id])
        #expect(ItemProjectMapper.projects(for: ticket, in: [a, b]).map(\.id) == [a.id, b.id])
        let remote = Project.make(remoteUrl: "git@git.example:shop/repo.git")
        #expect(ItemProjectMapper.projects(for: .request(remote: "https://git.example/shop/repo", number: 7), in: [remote]).map(\.id) == [remote.id])
        #expect(ItemProjectMapper.projects(for: .ticket(site: "https://other.example", key: "PAY-1"), in: [a]).isEmpty)
    }

    @Test func labelsStatusesAndApproximateCountUseTheirPagedEndpoints() async throws {
        let stub = StubSession { request in
            switch request.url?.path {
            case "/rest/api/3/label": return (200, Data(#"{"isLast":true,"values":["agent","ready"]}"#.utf8))
            case "/rest/api/3/statuses/search": return (200, Data(#"{"isLast":true,"values":[{"id":"1","name":"Done"}]}"#.utf8))
            case "/rest/api/3/search/approximate-count": return (200, Data(#"{"count":31}"#.utf8))
            default: Issue.record("Unexpected endpoint"); return (404, Data())
            }
        }
        let client = JiraClient(config: config, session: stub.session)
        #expect(try await client.labels() == ["agent", "ready"])
        #expect(try await client.statuses().map(\.name) == ["Done"])
        #expect(try await client.approximateCount(jql: "project = PAY") == 31)
    }

    @Test func unchangedRequestsReuseThreadsAndNewActivityIsReadAgain() async throws {
        let request = MergeRequest(iid: 7, title: "Mine", sourceBranch: "work", targetBranch: "main", author: "me", state: "open", draft: false, url: "https://git.example/shop/repo/-/merge_requests/7")
        let item = SignalItem(item: .request(remote: "https://git.example/shop/repo", number: 7), title: "Mine", mergeRequest: request, updated: now)
        let account = SignalAccountStub(read: SignalRead(items: [item], complete: true, accountUser: "me"))
        let reader = MyRequestReader(account: account, conditions: RequestConditions(event: .myRequest))
        #expect(try await reader.poll(since: nil, full: true).items.count == 1)
        #expect(try await reader.poll(since: nil, full: true).items.count == 1)
        #expect(await account.threadReads == 1)
        await account.workerReplied(at: now.addingTimeInterval(1))
        #expect(try await reader.poll(since: nil, full: true).items.isEmpty)
        #expect(await account.threadReads == 2)
    }


    @Test func gitHubErrorsBesideDataCannotBecomeACompleteListing() async throws {
        let stub = StubSession { _ in (200, Data(#"{"data":{"search":{"issueCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}},"errors":[{"message":"Read was truncated"}]}"#.utf8)) }
        let account = GitHubAccount(config: GitHubConfig(token: "test"), session: stub.session)
        await #expect(throws: GitHubError.refused("Read was truncated")) { try await account.requests(event: .reviewRequested, since: nil) }
    }

    @Test func gitLabMyRequestsReadAuthorAndAssigneeListings() async throws {
        let stub = StubSession { request in
            if request.url?.path == "/api/v4/user" { return (200, Data(#"{"username":"me"}"#.utf8)) }
            return (200, Data("[]".utf8))
        }
        let account = GitLabAccount(config: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "test"), session: stub.session)
        let read = try await HostUserMemo.$current.withValue(HostUserMemo.Cache()) { try await account.requests(event: .myRequest, since: nil) }
        #expect(read.complete && read.accountUser == "me")
        let filters = stub.requests.flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] }
        #expect(filters.contains(URLQueryItem(name: "author_username", value: "me")))
        #expect(filters.contains(URLQueryItem(name: "assignee_username[]", value: "me")))
    }

    @Test func gitLabFullPageReadsTheFollowingPageRatherThanCallingItComplete() async throws {
        let page = try JSONSerialization.data(withJSONObject: (1...100).map { n in
            ["iid": n, "title": "MR", "source_branch": "work", "target_branch": "main",
             "web_url": "https://git.example/shop/repo/-/merge_requests/\(n)"] as [String: Any]
        })
        let stub = StubSession { request in
            if request.url?.path == "/api/v4/user" { return (200, Data(#"{"username":"me"}"#.utf8)) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return (200, query.contains(URLQueryItem(name: "page", value: "2")) ? Data("[]".utf8) : page)
        }
        let account = GitLabAccount(config: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "test"), session: stub.session)
        let read = try await HostUserMemo.$current.withValue(HostUserMemo.Cache()) { try await account.requests(event: .reviewRequested, since: nil) }
        #expect(read.complete && read.items.count == 100 && stub.requests.count == 3)
    }

    @Test func gitHubMyRequestsSearchAuthorAndAssignee() async throws {
        let stub = StubSession { request in
            if request.url?.path == "/user" { return (200, Data(#"{"login":"me"}"#.utf8)) }
            return (200, Data(#"{"data":{"search":{"issueCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}}}"#.utf8))
        }
        let account = GitHubAccount(config: GitHubConfig(token: "test"), session: stub.session)
        let read = try await HostUserMemo.$current.withValue(HostUserMemo.Cache()) { try await account.requests(event: .myRequest, since: nil) }
        #expect(read.complete && read.accountUser == "me")
        let queries = stub.requests.compactMap { request -> String? in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            return (body?["variables"] as? [String: Any])?["query"] as? String
        }
        #expect(queries == ["is:pr is:open author:@me", "is:pr is:open assignee:@me"])
    }

    @Test func anInvalidRepositoryFilterDoesNotExpandToEveryRepository() async throws {
        let request = MergeRequest(iid: 7, title: "Mine", sourceBranch: "work", targetBranch: "main", author: "me", state: "open", draft: false, url: "https://git.example/shop/repo/-/merge_requests/7")
        let item = SignalItem(item: .request(remote: "https://git.example/shop/repo", number: 7), title: "Mine", mergeRequest: request, assignees: ["me"])
        let account = SignalAccountStub(read: SignalRead(items: [item], complete: true, accountUser: "me"))
        let reader = MyRequestReader(account: account, conditions: RequestConditions(event: .myRequest, waitingOnMyReply: false, projects: ["not-a-remote"]))
        #expect(try await reader.poll(since: nil, full: true).items.isEmpty)
        #expect(await account.threadReads == 0)
    }

}


private actor SignalAccountStub: SignalAccountReading {
    var read: SignalRead
    var threadReads = 0
    var author = "colleague"
    init(read: SignalRead) { self.read = read }
    func requests(event: RequestConditions.Event, since: Date?) async throws -> SignalRead { read }
    func threads(of request: SignalRequestRef) async throws -> [ReviewThread] {
        threadReads += 1
        return [ReviewThread(id: "thread", resolved: false, lastAuthor: author, lastBody: "Reply")]
    }
    func workerReplied(at: Date) { read.items[0].updated = at; author = "me" }
}
