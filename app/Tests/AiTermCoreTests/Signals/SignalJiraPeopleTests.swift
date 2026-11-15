import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct SignalJiraPeopleTests {
    @Test func peopleAreSearchedByNameAndSavedChoicesResolvedByAccountIdWithoutRequiringEmail() async throws {
        let stub = StubSession { request in
            #expect(request.httpMethod == "GET" && request.url!.path == "/rest/api/3/user/search")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.contains { $0.name == "query" && $0.value == "Sara" }
                    || query.contains { $0.name == "accountId" && $0.value == "account-7" })
            return (200, Data(#"[{"accountId":"account-7","displayName":"Sara","emailAddress":null}]"#.utf8))
        }
        let client = JiraClient(config: .init(siteURL: URL(string: "https://jira.example")!, email: "fake@example.invalid", token: "fake"), session: stub.session)
        let found = try await client.signalUsers(query: "Sara")
        #expect(found == [JiraUser(accountId: "account-7", displayName: "Sara", email: nil)])
        #expect(try await client.signalUsers(accountId: "account-7") == found)
        #expect(stub.requests.count == 2)
    }
}
