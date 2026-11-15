import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalHostIOTests {
    @Test func ticketStatusNeedsOnlyItsJiraReadAndNeverRequiresARequest() async throws {
        var world = SignalWorld(); let signal = world.signal(done: .ticketStatus("Done")); let id = world.workingTask(signal: signal)
        let ticket = world.ticket().ticket.map(JiraRef.init)
        world.state.updateSignalItem(id) { $0.jira = ticket }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { request in
            #expect(request.url!.host == "jira.example" && request.httpMethod == "POST")
            return (200, Data(#"{"issues":[{"key":"PAY-1","fields":{"summary":"Safe retries","status":{"name":"Done"}}}],"isLast":true}"#.utf8))
        }
        let links = SignalConnections(jira: JiraConfig(siteURL: URL(string: "https://jira.example")!, email: "fake", token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: GitRunner.hermetic(), connections: { links })
        io.remote = { _, _ in Issue.record("A ticket status must not read a code-host remote."); return "" }
        let snapshot = try await io.read(try #require(h.workspace.state.task(id: id)))
        #expect(snapshot.facts.ticketReadComplete && snapshot.facts.ticketStatus == "Done")
        #expect(!snapshot.canMerge && snapshot.reference == nil)
        #expect(stub.requests.count == 1)
    }
    @Test func operatorJudgmentSpendsNoSourceRead() async throws {
        var world = SignalWorld(); let signal = world.signal(); let id = world.workingTask(signal: signal)
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let io = SignalHostIO(workspace: h.workspace, git: GitRunner.hermetic(), connections: {
            Issue.record("A judgment-only stage needs no source read."); return SignalConnections()
        })
        let snapshot = try await io.read(try #require(h.workspace.state.task(id: id)))
        #expect(!snapshot.canMerge && !snapshot.facts.operatorJudged)
    }
    @Test func anOldRequestLinkCannotBeReadOrMergedInAChangedRepository() async throws {
        var world = SignalWorld(); let signal = world.signal(done: .hasReviewer); let id = world.workingTask(signal: signal)
        world.state.updateSignalItem(id) {
            $0.mr = MergeRequestRef(iid: 7, title: "Old request", url: "https://git.example/other/web/-/merge_requests/7")
        }
        let h = try SignalHarness(world); defer { h.cleanUp() }
        let stub = StubSession { _ in
            Issue.record("A request bound to another repository must be refused before any host read.")
            return (404, Data())
        }
        let links = SignalConnections(gitLab: GitLabConfig(hostURL: URL(string: "https://git.example")!, token: "fake"), session: stub.session)
        let io = SignalHostIO(workspace: h.workspace, git: GitRunner.hermetic(), connections: { links })
        io.remote = { _, _ in "git@git.example:shop/web.git" }
        await #expect(throws: (any Error).self) { try await io.read(try #require(h.workspace.state.task(id: id))) }
        #expect(stub.requests.isEmpty)
    }
}
