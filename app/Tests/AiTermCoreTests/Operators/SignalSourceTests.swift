import Foundation
import Testing
import Synchronization
@testable import AiTermCore
@testable import AiTermTestSupport

/// Synthetic response recordings drawn from the Jira enhanced-search and GitHub GraphQL search
/// schemas on 14 Nov 2026. No account or live ticket is represented.
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
        let reader = JiraQueryReader(client: JiraClient(config: config, session: stub.session), jql: "labels = agent", now: { now })
        let read = try await reader.poll(since: nil, full: true)
        #expect(read.complete && read.items.count == 2 && read.cursor == now)
        #expect(read.items[0].ticket?.labels == ["agent"] && read.items[0].ticket?.project == "PAY")
        #expect(read.items[0].ticket?.assignee == "me" && read.items[0].description == "Details")
        #expect(stub.requests.count == 2)
    }

    @Test func jiraReaderSendsTheJQLItIsGiven() async throws {
        let jql = #"project = SHOP AND labels = "needs review" ORDER BY updated DESC"#
        let stub = StubSession { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            #expect(body?["jql"] as? String == jql)
            return (200, Data(#"{"isLast":true,"issues":[{"key":"SHOP-412","fields":{"summary":"Review"}}]}"#.utf8))
        }
        let reader = JiraQueryReader(client: JiraClient(config: config, session: stub.session), jql: jql, now: { now })
        let read = try await reader.poll(since: nil, full: true)
        #expect(read.complete && read.items.count == 1 && stub.requests.count == 1)
    }

    /// A Done query's own ordering stays outside the ticket's narrowing, where Jira accepts it.
    @Test func aTicketsDoneJQLKeepsItsOrderingOutsideTheNarrowing() {
        #expect(JiraQueryReader.ticket("SHOP-412", matching: "status = Done ORDER BY updated DESC")
                == #"key = "SHOP-412" AND (status = Done) ORDER BY updated DESC"#)
        #expect(JiraQueryReader.ticket("SHOP-412", matching: "status = Done") == #"key = "SHOP-412" AND (status = Done)"#)
        #expect(JiraQueryReader.ticket("SHOP-412") == #"key = "SHOP-412""#)
    }

    @Test func jiraMalformedEntryOrRepeatedCursorMakesTheWholeReadIncomplete() async throws {
        let stub = StubSession { _ in
            (200, Data(#"{"nextPageToken":"repeat","isLast":false,"issues":[{"key":"PAY-1","fields":{"summary":"Valid"}},{}]}"#.utf8))
        }
        let reader = JiraQueryReader(client: JiraClient(config: config, session: stub.session), jql: "project = PAY", now: { now })
        let read = try await reader.poll(since: nil, full: true)
        #expect(!read.complete && read.cursor == nil)
        #expect(stub.requests.count <= 2)
    }

    @Test func jiraRateLimitDoesNotReturnAnEmptyCompleteRead() async throws {
        let stub = StubSession { _ in (429, Data()) }
        let reader = JiraQueryReader(client: JiraClient(config: config, session: stub.session), jql: "project = PAY", now: { now })
        await #expect(throws: JiraError.badResponse(429)) { try await reader.poll(since: nil, full: true) }
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
        let read = try await account.requests(matching: GitHubQuery.start("user-review-requested:@me"))
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

    /// The query writer's context reads only as many labels as it names, however many pages Jira has.
    @Test func aLimitedLabelReadStopsOnceItHasEnough() async throws {
        let stub = StubSession { _ in (200, Data(#"{"isLast":false,"values":["agent","ready","later"]}"#.utf8)) }
        #expect(try await JiraClient(config: config, session: stub.session).labels(limit: 2) == ["agent", "ready"])
        #expect(stub.requests.count == 1)
    }

    /// A written query is checked by Jira's strict parse, whose errors come back in Jira's own words.
    @Test func jqlIsCheckedByJirasStrictParse() async throws {
        let stub = StubSession { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: [String]]
            let query = body?["queries"]?.first ?? ""
            let errors = query.contains("statuz") ? #","errors":["Field 'statuz' does not exist or you do not have permission to view it."]"# : ""
            return (200, Data(#"{"queries":[{"query":"\#(query)"\#(errors)}]}"#.utf8))
        }
        let client = JiraClient(config: config, session: stub.session)
        #expect(try await client.jqlErrors("assignee = currentUser()").isEmpty)
        #expect(try await client.jqlErrors("statuz = Done") == ["Field 'statuz' does not exist or you do not have permission to view it."])
        let request = try #require(stub.lastRequest)
        #expect(request.httpMethod == "POST" && request.url?.path == "/rest/api/3/jql/parse" && request.url?.query == "validation=strict")
    }

    /// A written GitHub query is checked by one page of GitHub's search, which refuses a bad qualifier in its own words.
    @Test func aGitHubQueryIsCheckedByOneSearchPage() async throws {
        let stub = StubSession { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            let query = ((body?["variables"] as? [String: Any])?["query"] as? String) ?? ""
            if query.contains("review:maybe") { return (200, Data(#"{"errors":[{"message":"Invalid review qualifier"}]}"#.utf8)) }
            return (200, Data(#"{"data":{"search":{"issueCount":250,"pageInfo":{"hasNextPage":true,"endCursor":"next"},"nodes":[]}}}"#.utf8))
        }
        let account = GitHubAccount(config: GitHubConfig(token: "test"), session: stub.session)
        try await account.check(GitHubQuery.done("reviewed-by:@me"))
        #expect(stub.requests.count == 1, "one page, though more follow")
        await #expect(throws: GitHubError.refused("Invalid review qualifier")) { try await account.check(GitHubQuery.done("review:maybe")) }
    }

    @Test func gitHubErrorsBesideDataCannotBecomeACompleteListing() async throws {
        let stub = StubSession { _ in (200, Data(#"{"data":{"search":{"issueCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}},"errors":[{"message":"Read was truncated"}]}"#.utf8)) }
        let account = GitHubAccount(config: GitHubConfig(token: "test"), session: stub.session)
        await #expect(throws: GitHubError.refused("Read was truncated")) { try await account.requests(matching: GitHubQuery.start("user-review-requested:@me")) }
    }
}
