import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalConnectionsTests {
    @Test func theSameStartQuerySharesReadsAndCredentialsInvalidateTheReader() throws {
        var world = SignalWorld(); _ = world.signal(); var first = world.state.signals[0]
        first.start = SignalTrigger(source: .jira, description: "Payments", query: "project = PAY")
        var second = first; second.id = UUID(); second.start.description = "Other words"
        second.done = SignalTrigger(source: .gitLab, query: "reviewer:any")
        var other = first; other.id = UUID(); other.start.query = "project = SHOP"
        let links = SignalConnections(jira: JiraConfig(siteURL: URL(string: "https://jira.example")!, email: "fake", token: "private-one"))
        let shared = links.registrations(for: [first, second, other])
        #expect(shared.count == 3)
        #expect(shared[0].readKey == shared[1].readKey && shared[0].readKey != shared[2].readKey)
        #expect(!shared[0].readKey.contains("private-one"))
        var changed = links; changed.jira = JiraConfig(siteURL: links.jira!.siteURL, email: "fake", token: "private-two")
        #expect(changed.registrations(for: [first])[0].readKey != shared[0].readKey)
    }
    @Test func disconnectedSourcesNeverReturnAnEmptySuccessfulPreview() async throws {
        let connections = SignalConnections()
        for source in SignalTrigger.Source.allCases {
            #expect(throws: (any Error).self) { try connections.reader(for: SignalTrigger(source: source, query: "assignee:@me")) }
        }
        var world = SignalWorld(); _ = world.signal()
        let registered = try #require(connections.registrations(for: world.state.signals).first)
        await #expect(throws: (any Error).self) { try await registered.reader.poll(since: nil, full: true) }
    }

    /// A written query is checked by AiTerm's own reading first, then by Jira's strict parse or GitHub's search; a host that
    /// is not connected leaves it unchecked rather than refused, so the writer does not try again.
    @Test func aWrittenQueryIsCheckedWhereItWillRun() async {
        let stub = StubSession { request in
            if request.url?.path == "/rest/api/3/jql/parse" {
                return (200, Data(#"{"queries":[{"query":"x","errors":["Field 'statuz' does not exist."]}]}"#.utf8))
            }
            return (200, Data(#"{"data":{"search":{"issueCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}}}"#.utf8))
        }
        let links = SignalConnections(jira: JiraConfig(siteURL: URL(string: "https://jira.example")!, email: "fake", token: "test"),
                                      gitHub: GitHubConfig(token: "test"), session: stub.session)
        #expect(await links.check(.jira, start: true, query: "statuz = Done") == .refused("Field 'statuz' does not exist."))
        #expect(await links.check(.gitHub, start: false, query: "reviewed-by:@me") == .passed)
        #expect(await links.check(.gitLab, start: true, query: "review-state:unreviewed")
                == .refused("Name yourself in one role: author:@me, assignee:@me or reviewer:@me."))
        #expect(await links.check(.gitLab, start: true, query: "reviewer:@me") == .passed)
        #expect(stub.requests.count == 2, "GitLab's syntax is AiTerm's alone")
        #expect(await SignalConnections().check(.jira, start: true, query: "status = Done") == .unchecked("Connect Jira in Settings to check it."))
    }
}
