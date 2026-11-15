import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalConnectionsTests {
    @Test func manualJQLSharesReadsDespiteHiddenChipsAndCredentialsInvalidateTheReader() throws {
        var world = SignalWorld(); _ = world.signal(); var first = world.state.signals[0]
        first.source = .jira(JiraConditions(labels: ["hidden"], jql: "project = PAY"))
        var second = first; second.id = UUID(); second.source = .jira(JiraConditions(labels: ["different"], jql: "project = PAY"))
        let links = SignalConnections(jira: JiraConfig(siteURL: URL(string: "https://jira.example")!, email: "fake", token: "private-one"))
        let shared = links.registrations(for: [first, second])
        #expect(shared.count == 2)
        #expect(shared[0].readKey == shared[1].readKey)
        #expect(!shared[0].readKey.contains("private-one"))
        var changed = links; changed.jira = JiraConfig(siteURL: links.jira!.siteURL, email: "fake", token: "private-two")
        #expect(changed.registrations(for: [first])[0].readKey != shared[0].readKey)
    }
    @Test func disconnectedSourcesNeverReturnAnEmptySuccessfulPreview() async throws {
        let connections = SignalConnections()
        #expect(throws: (any Error).self) { try connections.reader(for: .jira(JiraConditions())) }
        var world = SignalWorld(); _ = world.signal()
        let registered = try #require(connections.registrations(for: world.state.signals).first)
        await #expect(throws: (any Error).self) { try await registered.reader.poll(since: nil, full: true) }
    }
}
