import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct WorkerGuardHostTests {
    @Test func defaultBranchNamesComeFromFreshHostReads() async throws {
        let stub = StubSession { request in
            #expect(request.httpMethod == "GET")
            return (200, Data(#"{"default_branch":"trunk"}"#.utf8))
        }
        let github = GitHubClient(config: GitHubConfig(token: "fake"), repo: "shop/web", session: stub.session)
        let gitlab = GitLabClient(config: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), project: "shop/web", session: stub.session)
        #expect(try await github.defaultBranch() == "trunk")
        #expect(try await gitlab.defaultBranch() == "trunk")
        #expect(stub.requests.count == 2)
    }
    @Test func anUnreadableDefaultBranchNeverFallsBackToMain() async throws {
        let stub = StubSession { _ in (200, Data(#"{"default_branch":null}"#.utf8)) }
        let github = GitHubClient(config: GitHubConfig(token: "fake"), repo: "shop/web", session: stub.session)
        await #expect(throws: (any Error).self) { try await github.defaultBranch() }
    }
}
