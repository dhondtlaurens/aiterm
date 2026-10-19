import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// The Jira writes the Operator's Jira slice allows (spec §5): create, move, link. Never a comment.
@Suite struct JiraWritesTests {
    let config = JiraConfig(siteURL: URL(string: "https://example.atlassian.net")!, email: "me@example.com", token: "tok")

    func body(_ request: URLRequest?) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: Any])
    }

    @Test func createPostsADF() async throws {
        let stub = StubSession { _ in (201, Data(#"{"id":"10001","key":"PAY-232","self":"https://example.atlassian.net/rest/api/3/issue/10001"}"#.utf8)) }
        let key = try await JiraClient(config: config, session: stub.session)
            .createIssue(project: "PAY", type: "Task", summary: "A token in the log", description: "It leaks.\n\nSecond line one\nSecond line two", parent: "PAY-1")
        #expect(key == "PAY-232")
        let request = try #require(stub.lastRequest)
        #expect(request.httpMethod == "POST" && request.url?.path == "/rest/api/3/issue")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("me@example.com:tok".utf8).base64EncodedString())
        let fields = try #require(try body(request)["fields"] as? [String: Any])
        #expect((fields["project"] as? [String: String]) == ["key": "PAY"])
        #expect((fields["issuetype"] as? [String: String]) == ["name": "Task"])
        #expect(fields["summary"] as? String == "A token in the log")
        #expect((fields["parent"] as? [String: String]) == ["key": "PAY-1"])
        let description = try #require(fields["description"] as? [String: Any])
        #expect(description["type"] as? String == "doc" && description["version"] as? Int == 1)
        // The description reads back through ADFText as it was written.
        #expect(ADFText.plain(description) == "It leaks.\n\nSecond line one\nSecond line two")
    }

    @Test func createWithoutADescriptionOrParentSendsNeither() async throws {
        let stub = StubSession { _ in (201, Data(#"{"key":"PAY-3"}"#.utf8)) }
        _ = try await JiraClient(config: config, session: stub.session).createIssue(project: "PAY", type: "Task", summary: "s", description: "  ")
        let fields = try #require(try body(stub.lastRequest)["fields"] as? [String: Any])
        #expect(fields["description"] == nil && fields["parent"] == nil)
    }

    @Test func aRefusedCreateIsJirasError() async throws {
        let stub = StubSession { _ in (400, Data(#"{"errors":{"summary":"required"}}"#.utf8)) }
        await #expect(throws: JiraError.badResponse(400)) {
            _ = try await JiraClient(config: config, session: stub.session).createIssue(project: "PAY", type: "Task", summary: "", description: "")
        }
    }

    @Test func transitionPicksByStatusName() async throws {
        let moves = #"{"transitions":[{"id":"11","name":"Start","to":{"name":"In Progress"}},{"id":"31","name":"Finish up","to":{"name":"Done"}}]}"#
        let stub = StubSession { request in
            if request.url?.path.hasSuffix("/transitions") == true { return request.httpMethod == "GET" ? (200, Data(moves.utf8)) : (204, Data()) }
            return (200, Data(#"{"fields":{"status":{"name":"To Do"}}}"#.utf8))
        }
        let moved = try await JiraClient(config: config, session: stub.session).transition(key: "PAY-231", to: "done")
        #expect(moved)
        #expect(stub.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
                == ["GET /rest/api/3/issue/PAY-231", "GET /rest/api/3/issue/PAY-231/transitions", "POST /rest/api/3/issue/PAY-231/transitions"])
        #expect(stub.requests.first?.url?.query == "fields=status")
        #expect((try body(stub.lastRequest)["transition"] as? [String: String]) == ["id": "31"], "the transition's own name, Finish up, is not what picks it")
    }

    @Test func aStatusNoTransitionLeadsToMovesNothingAndSaysWhatIsOffered() async throws {
        let stub = StubSession { request in
            request.url?.path.hasSuffix("/transitions") == true
                ? (200, Data(#"{"transitions":[{"id":"11","name":"Start","to":{"name":"In Progress"}}]}"#.utf8))
                : (200, Data(#"{"fields":{"status":{"name":"To Do"}}}"#.utf8))
        }
        await #expect(throws: JiraError.noTransition(key: "PAY-231", status: "Done", offered: ["In Progress"])) {
            try await JiraClient(config: config, session: stub.session).transition(key: "PAY-231", to: "Done")
        }
        #expect(stub.requests.filter { $0.httpMethod == "POST" }.isEmpty, "nothing was posted")
        #expect(JiraError.noTransition(key: "PAY-231", status: "Done", offered: ["In Progress"]).errorDescription
                == "PAY-231 can’t move to “Done” from where it is. Jira offers: In Progress.")
    }

    @Test func aTicketAlreadyInTheStatusIsNotTransitioned() async throws {
        let stub = StubSession { _ in (200, Data(#"{"fields":{"status":{"name":"Done"}}}"#.utf8)) }
        let moved = try await JiraClient(config: config, session: stub.session).transition(key: "PAY-231", to: "done")
        #expect(!moved)
        #expect(stub.requests.count == 1 && stub.requests.first?.httpMethod == "GET", "one read of the status, nothing else")
    }

    @Test func linkPostsTheTypeAndBothEnds() async throws {
        let stub = StubSession { _ in (201, Data()) }
        try await JiraClient(config: config, session: stub.session).link(key: "PAY-1", to: "PAY-2", type: "Blocks")
        let request = try #require(stub.lastRequest)
        #expect(request.httpMethod == "POST" && request.url?.path == "/rest/api/3/issueLink")
        let sent = try body(request)
        #expect((sent["type"] as? [String: String]) == ["name": "Blocks"])
        #expect((sent["outwardIssue"] as? [String: String]) == ["key": "PAY-1"], "PAY-1 blocks PAY-2")
        #expect((sent["inwardIssue"] as? [String: String]) == ["key": "PAY-2"])
    }

    @Test func aKeyThatIsNoKeyNeverReachesTheNetwork() async throws {
        let stub = StubSession { _ in (200, Data()) }
        await #expect(throws: JiraError.badResponse(400)) {
            try await JiraClient(config: config, session: stub.session).transition(key: "PAY-1/../../x", to: "Done")
        }
        #expect(stub.requests.isEmpty)
    }
}
