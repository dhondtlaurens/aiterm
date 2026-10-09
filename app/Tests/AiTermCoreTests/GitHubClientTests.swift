import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct GitHubClientTests {
    let config = GitHubConfig(token: "ghp_tok")

    func pull(_ number: Int, title: String = "Add gift card", head: String = "feat-gift-card", author: String = "octocat",
              draft: Bool = false, headRepo: String? = "octocat/hello") -> [String: Any] {
        var headPart: [String: Any] = ["ref": head, "label": "\(headRepo?.split(separator: "/").first.map(String.init) ?? "ghost"):\(head)"]
        headPart["repo"] = headRepo.map { ["full_name": $0] as [String: Any] } ?? NSNull()
        return ["number": number, "title": title, "html_url": "https://github.com/octocat/hello/pull/\(number)",
                "draft": draft, "user": ["login": author], "head": headPart,
                "base": ["ref": "main", "repo": ["full_name": "octocat/hello"]]]
    }

    private func makeClient(_ handler: @escaping StubURLProtocol.Handler) -> (client: GitHubClient, stub: StubSession) {
        let stub = StubSession(handler: handler)
        return (GitHubClient(config: config, session: stub.session), stub)
    }

    @Test func theListIsOpenPullsNewestFirstWithTheToken() async throws {
        let body = try JSONSerialization.data(withJSONObject: [pull(87)])
        let (client, stub) = makeClient { _ in (200, body) }
        let found = try await client.pullRequests(repo: "octocat/hello", search: "")
        #expect(found == [MergeRequest(iid: 87, title: "Add gift card", sourceBranch: "feat-gift-card", targetBranch: "main",
                                       author: "octocat", state: "open", draft: false,
                                       url: "https://github.com/octocat/hello/pull/87")])
        let req = try #require(stub.lastRequest)
        #expect(req.url?.absoluteString == "https://api.github.com/repos/octocat/hello/pulls?state=open&sort=updated&direction=desc&per_page=100")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_tok")
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(req.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(found.first?.lane == "Open")
        #expect(found.first?.reference == "#87")
    }

    @Test func searchFiltersByTitleBranchOrAuthorAndKeepsTwentyFive() async throws {
        let many = (1...40).map { pull($0, title: "Change \($0)", head: "topic-\($0)", author: $0 == 3 ? "Sam" : "octocat") }
        let body = try JSONSerialization.data(withJSONObject: many + [pull(99, title: "Gift CARD flow")])
        let (client, _) = makeClient { _ in (200, body) }
        #expect(try await client.pullRequests(repo: "octocat/hello", search: "gift card").map(\.iid) == [99])
        #expect(try await client.pullRequests(repo: "octocat/hello", search: "topic-12").map(\.iid) == [12])
        #expect(try await client.pullRequests(repo: "octocat/hello", search: "sam").map(\.iid) == [3])
        #expect(try await client.pullRequests(repo: "octocat/hello", search: "").count == 25)
    }

    @Test func aNumberFetchesThatPullRequest() async throws {
        let body = try JSONSerialization.data(withJSONObject: pull(87))
        let (client, stub) = makeClient { _ in (200, body) }
        for text in ["87", "#87", "!87", " #87 "] {
            #expect(try await client.pullRequests(repo: "octocat/hello", search: text).map(\.iid) == [87], "\(text)")
        }
        #expect(stub.lastRequest?.url?.absoluteString == "https://api.github.com/repos/octocat/hello/pulls/87")
    }

    @Test func aPullRequestFetchedByNumberShowsItsRealState() async throws {
        for (state, merged, lane) in [("closed", true, "Merged"), ("closed", false, "Closed"), ("open", false, "Open")] {
            var payload = pull(88)
            payload["state"] = state
            payload["merged"] = merged
            let body = try JSONSerialization.data(withJSONObject: payload)
            let (client, _) = makeClient { _ in (200, body) }
            let found = try await client.pullRequests(repo: "octocat/hello", search: "#88")
            #expect(found.first?.lane == lane, "\(state) merged \(merged)")
        }
    }

    @Test func anUnknownNumberIsNothingFound() async throws {
        let (client, _) = makeClient { _ in (404, Data()) }
        #expect(try await client.pullRequests(repo: "octocat/hello", search: "#9999") == [])
    }

    @Test func aPullRequestFromAForkSaysWhichFork() async throws {
        let body = try JSONSerialization.data(withJSONObject: [pull(5, head: "patch-1", headRepo: "someone/hello")])
        let (client, _) = makeClient { _ in (200, body) }
        let found = try #require(try await client.pullRequests(repo: "octocat/hello", search: "").first)
        #expect(found.forkHead == "someone:patch-1")
        #expect(found.lane == "Fork")
    }

    /// Review focus 5: a fork deleted after its pull request was opened leaves `head.repo` null.
    @Test func aPullRequestFromADeletedForkIsStillListed() async throws {
        let body = try JSONSerialization.data(withJSONObject: [pull(6, head: "patch-2", headRepo: nil), pull(7)])
        let (client, _) = makeClient { _ in (200, body) }
        let found = try await client.pullRequests(repo: "octocat/hello", search: "")
        #expect(found.map(\.iid) == [6, 7])
        #expect(found.first?.forkHead == "ghost:patch-2")
        #expect(found.last?.forkHead == nil)
    }

    @Test func aMalformedEntryDropsOnlyItself() async throws {
        let body = try JSONSerialization.data(withJSONObject: [["number": "x"], pull(7)])
        let (client, _) = makeClient { _ in (200, body) }
        #expect(try await client.pullRequests(repo: "octocat/hello", search: "").map(\.iid) == [7])
    }

    @Test func statusCodesMapToErrors() async {
        for (status, error) in [(401, GitHubError.unauthorized), (403, .forbidden), (404, .repoNotFound("octocat/hello")), (500, .badResponse(500))] {
            await #expect(throws: error) { _ = try await self.makeClient { _ in (status, Data()) }.client.pullRequests(repo: "octocat/hello", search: "") }
        }
        await #expect(throws: GitHubError.decoding) {
            _ = try await self.makeClient { _ in (200, Data("<html>".utf8)) }.client.pullRequests(repo: "octocat/hello", search: "")
        }
    }

    @Test func eachErrorHasItsLine() {
        #expect(GitHubError.unauthorized.errorDescription == "Check your GitHub access token in Settings › Integrations.")
        #expect(GitHubError.forbidden.errorDescription == "GitHub refused: the token can’t read this repository, or the rate limit was reached.")
        #expect(GitHubError.repoNotFound("octocat/hello").errorDescription == "GitHub has no repository at octocat/hello, or your token cannot see it.")
    }

    @Test func testConnectionReturnsTheLogin() async throws {
        let (client, stub) = makeClient { _ in (200, Data(#"{"login":"octocat"}"#.utf8)) }
        #expect(try await client.testConnection() == "octocat")
        #expect(stub.lastRequest?.url?.absoluteString == "https://api.github.com/user")
    }

    @Test func theTokenDoesNotFollowARedirectOffGitHubsAPI() async throws {
        let first = URL(string: "https://api.github.com/repos/octocat/hello/pulls?state=open&sort=updated&direction=desc&per_page=100")!
        let elsewhere = URL(string: "https://evil.example.com/pulls")!
        let stub = RedirectSession(redirects: [first: elsewhere], body: Data("[]".utf8))
        _ = try await GitHubClient(config: config, session: stub.session).pullRequests(repo: "octocat/hello", search: "")
        #expect(stub.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer ghp_tok", nil])
    }

    @Test func refsKnowTheirHost() {
        #expect(MergeRequestRef(iid: 87, title: "t", url: "https://github.com/octocat/hello/pull/87").reference == "#87")
        #expect(MergeRequestRef(iid: 4, title: "t", url: "https://git.example.net/web/acme-web/-/merge_requests/4").reference == "!4")
    }

    /// One page of GraphQL's answer for a pull request's review threads.
    private static func threadsPage(_ resolved: [Bool], next: String? = nil) throws -> Data {
        let threads: [String: Any] = ["pageInfo": ["hasNextPage": next != nil, "endCursor": next.map { $0 as Any } ?? NSNull()],
                                      "nodes": resolved.map { ["isResolved": $0] }]
        return try JSONSerialization.data(withJSONObject: ["data": ["repository": ["pullRequest": ["reviewThreads": threads]]]])
    }

    /// What a GraphQL request sent as its variables.
    private static func variables(of request: URLRequest) -> [String: Any] {
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
        return body?["variables"] as? [String: Any] ?? [:]
    }

    /// REST has no review threads; GraphQL does. One query, read-only, with the same token.
    @Test func reviewThreadsAskGraphQLForThePullRequestsThreads() async throws {
        let body = try Self.threadsPage([true, false, true])
        let (client, stub) = makeClient { _ in (200, body) }
        #expect(try await client.reviewThreads(repo: "octocat/hello", number: 87) == ReviewThreads(resolved: 2, total: 3))
        let req = try #require(stub.lastRequest)
        #expect(req.url?.absoluteString == "https://api.github.com/graphql")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer ghp_tok")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sent = try #require(try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any])
        let query = try #require(sent["query"] as? String)
        #expect(query.hasPrefix("query("))
        #expect(!query.contains("mutation"))
        #expect(query.contains("reviewThreads(first: 100, after: $after)"))
        let variables = Self.variables(of: req)
        #expect(variables["owner"] as? String == "octocat")
        #expect(variables["name"] as? String == "hello")
        #expect(variables["number"] as? Int == 87)
        #expect(variables["after"] == nil)
    }

    /// Review focus 4: the next page is asked for by the cursor the last one ended at.
    @Test func reviewThreadsFollowTheCursor() async throws {
        let first = try Self.threadsPage([true, true], next: "c1"), second = try Self.threadsPage([false])
        let (client, stub) = makeClient { request in (200, Self.variables(of: request)["after"] as? String == "c1" ? second : first) }
        #expect(try await client.reviewThreads(repo: "octocat/hello", number: 87) == ReviewThreads(resolved: 2, total: 3))
        #expect(stub.requests.map { Self.variables(of: $0)["after"] as? String } == [nil, "c1"])
    }

    /// Review focus 4: a cursor that never ends is followed ten pages and no further.
    @Test func reviewThreadsStopAtTenPagesToo() async throws {
        let endless = try Self.threadsPage([true], next: "again")
        let (client, stub) = makeClient { _ in (200, endless) }
        #expect(try await client.reviewThreads(repo: "octocat/hello", number: 87) == ReviewThreads(resolved: 10, total: 10))
        #expect(stub.requests.count == GitHubClient.threadPages)
    }

    /// Review focus 3: GraphQL answers 200 with the repository or pull request null, and says why in
    /// `errors`. That is not a pull request without threads.
    @Test func aRepositoryOrPullRequestGraphQLCannotSeeThrows() async {
        let cases: [(String, GitHubError)] = [
            (#"{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository"}]}"#, .repoNotFound("octocat/hello")),
            (#"{"data":{"repository":{"pullRequest":null}},"errors":[{"type":"NOT_FOUND"}]}"#, .repoNotFound("octocat/hello")),
            (#"{"data":{"repository":null},"errors":[{"type":"FORBIDDEN","message":"Resource protected by organization SAML enforcement"}]}"#, .forbidden),
            (#"{"data":null,"errors":[{"message":"Something went wrong"}]}"#, .repoNotFound("octocat/hello")),
        ]
        for (body, error) in cases {
            await #expect(throws: error, "\(body)") {
                _ = try await self.makeClient { _ in (200, Data(body.utf8)) }.client.reviewThreads(repo: "octocat/hello", number: 87)
            }
        }
        await #expect(throws: GitHubError.unauthorized) {
            _ = try await self.makeClient { _ in (401, Data()) }.client.reviewThreads(repo: "octocat/hello", number: 87)
        }
    }

    /// A repository that is not `owner/name` is not asked about at all.
    @Test func aRepositoryWithoutAnOwnerIsNotAsked() async {
        let (client, stub) = makeClient { _ in (200, Data()) }
        await #expect(throws: GitHubError.repoNotFound("hello")) { _ = try await client.reviewThreads(repo: "hello", number: 87) }
        #expect(stub.requests.isEmpty)
    }
}
