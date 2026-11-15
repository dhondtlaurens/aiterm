import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct SignalReviewActivityTests {
    let stamp = "2026-11-15T01:05:00Z"
    @Test func reviewersIncludeGitHubTeamsAndGitLabPeople() async throws {
        let stub = StubSession { request in
            if request.url!.host == "api.github.com" {
                return (200, Data(#"{"users":[{"login":"sara"}],"teams":[{"slug":"ios"}]}"#.utf8))
            }
            return (200, Data(#"{"reviewers":[{"username":"sara"}]}"#.utf8))
        }
        let github = GitHubClient(config: .init(token: UUID().uuidString), repo: "shop/web", session: stub.session)
        let gitlab = GitLabClient(config: .init(hostURL: URL(string: "https://git.example")!, token: UUID().uuidString),
                                 project: "shop/web", session: stub.session)
        #expect(try await github.signalReviewers(of: 7) == ["sara", "team:ios"])
        #expect(try await gitlab.signalReviewers(of: 7) == ["sara"])
        #expect(stub.requests.allSatisfy { $0.httpMethod == "GET" })
    }
    @Test(arguments: ["review", "comment", "inline"])
    func githubCountsOnlySubmittedOwnActivityAtItsCreationDate(kind: String) async throws {
        let stamp = stamp
        let stub = StubSession { request in
            let path = request.url!.path
            if path == "/user" { return (200, Data(#"{"login":"me"}"#.utf8)) }
            let old = "2026-11-14T01:05:00Z"
            let value: String
            if path.hasSuffix("/reviews") {
                let posted = kind == "review" ? stamp : old
                value = """
                [{"id":1,"user":{"login":"me"},"state":"APPROVED","submitted_at":"\(posted)"},
                 {"id":2,"user":{"login":"me"},"state":"PENDING","created_at":"2099-01-01T00:00:00Z"}]
                """
            } else if path.contains("/issues/") {
                let posted = kind == "comment" ? stamp : old
                value = """
                [{"user":{"login":"me"},"created_at":"\(posted)","updated_at":"2099-01-01T00:00:00Z"},
                 {"user":{"login":"other"},"created_at":"2099-01-01T00:00:00Z"}]
                """
            } else {
                let posted = kind == "inline" ? stamp : old
                value = """
                [{"user":{"login":"me"},"pull_request_review_id":1,"created_at":"\(posted)"},
                 {"user":{"login":"me"},"pull_request_review_id":2,"created_at":"2099-01-01T00:00:00Z"}]
                """
            }
            return (200, Data(value.utf8))
        }
        let host = GitHubClient(config: .init(token: UUID().uuidString), repo: "shop/web", session: stub.session)
        #expect(try await host.mySignalReviewPostedAt(of: 7) == ISO8601DateFormatter().date(from: stamp))
        #expect(stub.requests.allSatisfy { $0.httpMethod == "GET" })
    }
    @Test func gitlabCountsOwnCommentsAndApprovalNotesButNoOtherSystemActivity() async throws {
        let stamp = stamp
        let stub = StubSession { request in
            if request.url!.path == "/api/v4/user" { return (200, Data(#"{"username":"me"}"#.utf8)) }
            return (200, Data("""
            [{"author":{"username":"me"},"system":false,"body":"Reviewed it","created_at":"2026-11-14T01:05:00Z"},
             {"author":{"username":"me"},"system":true,"body":"approved this merge request","created_at":"\(stamp)"},
             {"author":{"username":"me"},"system":true,"body":"changed title","created_at":"2099-01-01T00:00:00Z"},
             {"author":{"username":"other"},"system":false,"body":"Reviewed it","created_at":"2099-01-01T00:00:00Z"}]
            """.utf8))
        }
        let host = GitLabClient(config: .init(hostURL: URL(string: "https://git.example")!, token: UUID().uuidString),
                               project: "shop/web", session: stub.session)
        #expect(try await host.mySignalReviewPostedAt(of: 7) == ISO8601DateFormatter().date(from: stamp))
    }
    @Test func malformedActivityDoesNotLookLikeNoReview() async {
        let stub = StubSession { request in
            if request.url!.path == "/api/v4/user" { return (200, Data(#"{"username":"me"}"#.utf8)) }
            return (200, Data(#"[{"unreadable":true}]"#.utf8))
        }
        let host = GitLabClient(config: .init(hostURL: URL(string: "https://git.example")!, token: UUID().uuidString),
                               project: "shop/web", session: stub.session)
        await #expect(throws: (any Error).self) { try await host.mySignalReviewPostedAt(of: 7) }
    }
}
