import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// The Jira writes the Operator's Jira slice allows (spec §5, §L): create, move, link, edit and comment.
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

    /// A 4xx says what Jira did not like, in its words, and does not say to try again.
    @Test func aRefusedCreateCarriesJirasWords() async throws {
        let stub = StubSession { _ in (400, Data(#"{"errorMessages":["Bad project."],"errors":{"summary":"You must specify a summary.","issuetype":"Specify a valid issue type."}}"#.utf8)) }
        let error = await #expect(throws: JiraError.self) {
            _ = try await JiraClient(config: config, session: stub.session).createIssue(project: "PAY", type: "Nope", summary: "", description: "")
        }
        #expect(error == .refused(status: 400, detail: "Bad project.; issuetype: Specify a valid issue type.; summary: You must specify a summary."))
        #expect(error?.errorDescription == "Jira refused it (HTTP 400): Bad project.; issuetype: Specify a valid issue type.; summary: You must specify a summary.")
        #expect(error?.errorDescription?.contains("Try again") == false)
    }

    @Test func aMissingTicketIsRefusedWithItsMessageAndALongOneIsTrimmed() async throws {
        let missing = StubSession { _ in (404, Data(#"{"errorMessages":["Issue does not exist or you do not have permission to see it."],"errors":{}}"#.utf8)) }
        await #expect(throws: JiraError.refused(status: 404, detail: "Issue does not exist or you do not have permission to see it.")) {
            try await JiraClient(config: config, session: missing.session).transition(key: "PAY-9", to: "Done")
        }
        let long = StubSession { _ in (400, Data(("{\"errorMessages\":[\"" + String(repeating: "x", count: 500) + "\"]}").utf8)) }
        await #expect(throws: JiraError.refused(status: 400, detail: String(repeating: "x", count: 299) + "…")) {
            try await JiraClient(config: config, session: long.session).link(key: "PAY-1", to: "PAY-2", type: "Nope")
        }
        let noBody = StubSession { _ in (400, Data("<html>".utf8)) }
        await #expect(throws: JiraError.refused(status: 400, detail: "")) {
            try await JiraClient(config: config, session: noBody.session).link(key: "PAY-1", to: "PAY-2", type: "Nope")
        }
        #expect(JiraError.refused(status: 400, detail: "").errorDescription == "Jira refused it (HTTP 400).")
    }

    @Test func aServerErrorOrRateLimitStillSaysToTryAgainAndSignInStaysSignIn() async throws {
        for (status, expected) in [(500, JiraError.badResponse(500)), (429, .badResponse(429)), (401, .unauthorized), (403, .unauthorized)] {
            let stub = StubSession { _ in (status, Data(#"{"errorMessages":["x"]}"#.utf8)) }
            await #expect(throws: expected) {
                try await JiraClient(config: config, session: stub.session).link(key: "PAY-1", to: "PAY-2", type: "Blocks")
            }
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
        await #expect(throws: JiraError.refused(status: 400, detail: "PAY-1/../../x isn’t a Jira ticket key.")) {
            try await JiraClient(config: config, session: stub.session).transition(key: "PAY-1/../../x", to: "Done")
        }
        #expect(stub.requests.isEmpty)
    }

    @Test func createSendsItsLabels() async throws {
        let stub = StubSession { _ in (201, Data(#"{"key":"PAY-4"}"#.utf8)) }
        _ = try await JiraClient(config: config, session: stub.session)
            .createIssue(project: "PAY", type: "Task", summary: "s", description: "", labels: ["aiterm-1a2b3c4d-t1"])
        let fields = try #require(try body(stub.lastRequest)["fields"] as? [String: Any])
        #expect(fields["labels"] as? [String] == ["aiterm-1a2b3c4d-t1"])
    }

    /// A move reads the ticket and its transitions first: what `beforeWrite` refuses after those reads is not moved.
    @Test func aMoveStopsWhenItsLastCheckRefuses() async throws {
        struct Paused: Error {}
        let moves = #"{"transitions":[{"id":"31","name":"Finish","to":{"name":"Done"}}]}"#
        let stub = StubSession { request in
            if request.url?.path.hasSuffix("/transitions") == true { return request.httpMethod == "GET" ? (200, Data(moves.utf8)) : (204, Data()) }
            return (200, Data(#"{"fields":{"status":{"name":"To Do"}}}"#.utf8))
        }
        await #expect(throws: Paused.self) {
            try await JiraClient(config: config, session: stub.session).transition(key: "PAY-231", to: "Done", beforeWrite: { throw Paused() })
        }
        #expect(stub.requests.map { $0.httpMethod ?? "" } == ["GET", "GET"], "read, then nothing posted")
    }

    // -- edit and comment (spec §L) ---------------------------------------------------------------

    @Test func anEditSendsLabelsAsOperationsAndTheDescriptionAsADF() async throws {
        let stub = StubSession { _ in (204, Data()) }
        let edit = JiraEdit(summary: "New title", description: "First.\n\nSecond", labelsAdd: ["web", "urgent"], labelsRemove: ["old"],
                            priority: "High", fixVersions: ["1.4", "1.5"])
        try await JiraClient(config: config, session: stub.session).edit(key: "PAY-9", fields: edit)
        let request = try #require(stub.lastRequest)
        #expect(stub.requests.count == 1, "nothing is read when no assignee is named")
        #expect(request.httpMethod == "PUT" && request.url?.path == "/rest/api/3/issue/PAY-9")
        let sent = try body(request)
        let fields = try #require(sent["fields"] as? [String: Any])
        #expect(fields["summary"] as? String == "New title")
        #expect((fields["priority"] as? [String: String]) == ["name": "High"])
        #expect((fields["fixVersions"] as? [[String: String]]) == [["name": "1.4"], ["name": "1.5"]])
        #expect(fields["assignee"] == nil && fields["labels"] == nil, "labels are operations, not a replacement")
        let description = try #require(fields["description"] as? [String: Any])
        #expect(description["type"] as? String == "doc" && ADFText.plain(description) == "First.\n\nSecond")
        let update = try #require(sent["update"] as? [String: Any])
        let labels = try #require(update["labels"] as? [[String: String]])
        #expect(labels == [["add": "web"], ["add": "urgent"], ["remove": "old"]])
    }

    @Test func anEditSendsOnlyWhatItNames() async throws {
        let stub = StubSession { _ in (204, Data()) }
        try await JiraClient(config: config, session: stub.session).edit(key: "PAY-9", fields: JiraEdit(labelsRemove: ["old"]))
        let sent = try body(stub.lastRequest)
        #expect((sent["fields"] as? [String: Any])?.isEmpty == true)
        #expect((sent["update"] as? [String: Any])?["labels"] as? [[String: String]] == [["remove": "old"]])
        let none = StubSession { _ in (204, Data()) }
        try await JiraClient(config: config, session: none.session).edit(key: "PAY-9", fields: JiraEdit(summary: "s", fixVersions: []))
        let fields = try #require(try body(none.lastRequest)["fields"] as? [String: Any])
        #expect((fields["fixVersions"] as? [Any])?.isEmpty == true, "an empty list of versions clears them")
        #expect(try body(none.lastRequest)["update"] == nil)
    }

    @Test func anEmptyDescriptionClearsIt() async throws {
        let stub = StubSession { _ in (204, Data()) }
        try await JiraClient(config: config, session: stub.session).edit(key: "PAY-9", fields: JiraEdit(description: "  "))
        let fields = try #require(try body(stub.lastRequest)["fields"] as? [String: Any])
        #expect(fields["description"] is NSNull)
    }

    @Test func anEditWithNothingInItNeverReachesTheNetwork() async throws {
        let stub = StubSession { _ in (204, Data()) }
        #expect(JiraEdit().isEmpty && !JiraEdit(fixVersions: []).isEmpty && !JiraEdit(assignee: .unassigned).isEmpty)
        await #expect(throws: JiraError.refused(status: 400, detail: "An edit needs at least one field to change.")) {
            try await JiraClient(config: config, session: stub.session).edit(key: "PAY-9", fields: JiraEdit())
        }
        await #expect(throws: JiraError.refused(status: 400, detail: "PAY-1/../x isn’t a Jira ticket key.")) {
            try await JiraClient(config: config, session: stub.session).edit(key: "PAY-1/../x", fields: JiraEdit(summary: "s"))
        }
        #expect(stub.requests.isEmpty)
    }

    @Test func assigneeMeUsesMyself() async throws {
        let stub = StubSession { request in
            request.url?.path == "/rest/api/3/myself" ? (200, Data(#"{"accountId":"acc-me","displayName":"Me"}"#.utf8)) : (204, Data())
        }
        try await JiraClient(config: config, session: stub.session).edit(key: "PAY-9", fields: JiraEdit(assignee: .me))
        #expect(stub.requests.map { ($0.httpMethod ?? "") + " " + ($0.url?.path ?? "") } == ["GET /rest/api/3/myself", "PUT /rest/api/3/issue/PAY-9"])
        let fields = try #require(try body(stub.lastRequest)["fields"] as? [String: Any])
        #expect((fields["assignee"] as? [String: String]) == ["accountId": "acc-me"])
    }

    @Test func noAssigneeSendsANullAccount() async throws {
        let stub = StubSession { _ in (204, Data()) }
        try await JiraClient(config: config, session: stub.session).edit(key: "PAY-9", fields: JiraEdit(assignee: .unassigned))
        let fields = try #require(try body(stub.lastRequest)["fields"] as? [String: Any])
        let assignee = try #require(fields["assignee"] as? [String: Any])
        #expect(assignee["accountId"] is NSNull && stub.requests.count == 1)
    }

    @Test func aNamedAssigneeIsTheOneUserWhoMatches() async throws {
        let stub = StubSession { request in
            request.url?.path == "/rest/api/3/user/assignable/search"
                ? (200, Data(#"[{"accountId":"acc-sofie","displayName":"Sofie Jacobs","emailAddress":"sofie@example.com"},{"nope":1}]"#.utf8))
                : (204, Data())
        }
        try await JiraClient(config: config, session: stub.session).edit(key: "PAY-9", fields: JiraEdit(assignee: .query("sofie")))
        let search = try #require(stub.requests.first)
        #expect(search.url?.query?.contains("project=PAY") == true && search.url?.query?.contains("query=sofie") == true, "the ticket's own project")
        let fields = try #require(try body(stub.lastRequest)["fields"] as? [String: Any])
        #expect(fields["assignee"] as? [String: String] == ["accountId": "acc-sofie"])
    }

    @Test func anAmbiguousAssigneeIsRefusedWithTheCandidates() async throws {
        let stub = StubSession { _ in
            (200, Data(#"[{"accountId":"a","displayName":"Sofie Jacobs","emailAddress":"sj@example.com"},{"accountId":"b","displayName":"Sofie Peeters"}]"#.utf8))
        }
        let error = await #expect(throws: JiraError.self) {
            try await JiraClient(config: config, session: stub.session).edit(key: "PAY-9", fields: JiraEdit(summary: "s", assignee: .query("sofie")))
        }
        #expect(error == .refused(status: 400, detail: "“sofie” matches more than one assignable user: Sofie Jacobs (sj@example.com), Sofie Peeters. Use a fuller name or an email."))
        #expect(stub.requests.count == 1 && stub.lastRequest?.httpMethod == "GET", "nothing was written")
        let none = StubSession { _ in (200, Data("[]".utf8)) }
        await #expect(throws: JiraError.refused(status: 400, detail: "No assignable user in PAY matches “nobody”.")) {
            try await JiraClient(config: config, session: none.session).edit(key: "PAY-9", fields: JiraEdit(assignee: .query("nobody")))
        }
    }

    /// Jira's search is by substring, so `sofie@x.com` also finds `xsofie@x.com`: an exact email or name picks one.
    @Test func aQueryThatIsExactlyOneUsersEmailOrNameIsThatUser() async throws {
        let users = #"[{"accountId":"a","displayName":"Sofie","emailAddress":"sofie@x.com"},{"accountId":"b","displayName":"Xsofie Peeters","emailAddress":"xsofie@x.com"},{"accountId":"c","displayName":"Sofie Jacobs"}]"#
        for (query, account) in [("SOFIE@x.com", "a"), (" xsofie@x.com ", "b"), ("sofie jacobs", "c"), ("sofie", "a")] {
            let stub = StubSession { request in request.url?.path == "/rest/api/3/user/assignable/search" ? (200, Data(users.utf8)) : (204, Data()) }
            try await JiraClient(config: config, session: stub.session).edit(key: "PAY-9", fields: JiraEdit(assignee: .query(query)))
            let fields = try #require(try body(stub.lastRequest)["fields"] as? [String: Any])
            #expect(fields["assignee"] as? [String: String] == ["accountId": account], "\(query)")
        }
        // Two users with the same name stay ambiguous, and a part of a name is no exact match.
        let twins = StubSession { _ in (200, Data(#"[{"accountId":"a","displayName":"Sofie","emailAddress":"a@x.com"},{"accountId":"b","displayName":"sofie","emailAddress":"b@x.com"}]"#.utf8)) }
        await #expect(throws: JiraError.self) {
            try await JiraClient(config: config, session: twins.session).edit(key: "PAY-9", fields: JiraEdit(assignee: .query("Sofie")))
        }
        let part = StubSession { _ in (200, Data(#"[{"accountId":"a","displayName":"Sofie Jacobs"},{"accountId":"b","displayName":"Sofie Peeters"}]"#.utf8)) }
        await #expect(throws: JiraError.self) {
            try await JiraClient(config: config, session: part.session).edit(key: "PAY-9", fields: JiraEdit(assignee: .query("Sofie")))
        }
    }

    @Test func aTaggedCommentCarriesItsTagAsAProperty() async throws {
        let stub = StubSession { _ in (201, Data(#"{"id":"10042"}"#.utf8)) }
        _ = try await JiraClient(config: config, session: stub.session).comment(key: "PAY-9", body: "Hi.", tag: "aiterm-v2-abc")
        let properties = try #require(try body(stub.lastRequest)["properties"] as? [[String: Any]])
        #expect(properties.count == 1 && properties.first?["key"] as? String == "aiterm")
        #expect((properties.first?["value"] as? [String: String]) == ["call": "aiterm-v2-abc"])
        let plain = StubSession { _ in (201, Data(#"{"id":"1"}"#.utf8)) }
        _ = try await JiraClient(config: config, session: plain.session).comment(key: "PAY-9", body: "Hi.")
        #expect(try body(plain.lastRequest)["properties"] == nil)
    }

    @Test func aCommentIsFoundByItsTagAcrossPages() async throws {
        let stub = StubSession { request in
            request.url?.query?.contains("startAt=2") == true
                ? (200, Data(#"{"total":3,"comments":[{"id":"12","properties":[{"key":"aiterm","value":{"call":"mine"}}]}]}"#.utf8))
                : (200, Data(#"{"total":3,"comments":[{"id":"10"},{"id":"11","properties":[{"key":"other","value":{"call":"mine"}},{"key":"aiterm","value":{"call":"theirs"}},{"nope":1}]}]}"#.utf8))
        }
        let client = JiraClient(config: config, session: stub.session)
        #expect(try await client.findComment(key: "PAY-9", tag: "mine") == "12", "only an aiterm property counts")
        #expect(try await client.findComment(key: "PAY-9", tag: "theirs") == "11")
        #expect(try await client.findComment(key: "PAY-9", tag: "nobody") == nil)
        let first = try #require(stub.requests.first)
        #expect(first.httpMethod == "GET" && first.url?.path == "/rest/api/3/issue/PAY-9/comment" && first.url?.query?.contains("expand=properties") == true)
        await #expect(throws: JiraError.self) { _ = try await client.findComment(key: "x", tag: "t") }
    }

    @Test func assignableReadsUsers() async throws {
        let stub = StubSession { _ in (200, Data(#"[{"accountId":"a","displayName":"Sofie","emailAddress":"s@example.com"},{"accountId":"b","displayName":"Bram"}]"#.utf8)) }
        let users = try await JiraClient(config: config, session: stub.session).assignable(project: "PAY", query: "s")
        #expect(users == [JiraUser(accountId: "a", displayName: "Sofie", email: "s@example.com"), JiraUser(accountId: "b", displayName: "Bram", email: nil)])
        #expect(stub.lastRequest?.httpMethod == "GET" && stub.lastRequest?.url?.path == "/rest/api/3/user/assignable/search")
    }

    @Test func anEditStopsWhenItsLastCheckRefuses() async throws {
        struct Paused: Error {}
        let stub = StubSession { _ in (200, Data(#"{"accountId":"acc-me"}"#.utf8)) }
        await #expect(throws: Paused.self) {
            try await JiraClient(config: config, session: stub.session).edit(key: "PAY-9", fields: JiraEdit(assignee: .me), beforeWrite: { throw Paused() })
        }
        #expect(stub.requests.map { $0.httpMethod ?? "" } == ["GET"], "read, then nothing put")
    }

    @Test func aCommentIsSentAsADF() async throws {
        let stub = StubSession { _ in (201, Data(#"{"id":"10042","self":"https://example.atlassian.net/rest/api/3/issue/PAY-9/comment/10042"}"#.utf8)) }
        let id = try await JiraClient(config: config, session: stub.session).comment(key: "PAY-9", body: "Shipped in 1.4.\n\nSee the MR.")
        #expect(id == "10042")
        let request = try #require(stub.lastRequest)
        #expect(request.httpMethod == "POST" && request.url?.path == "/rest/api/3/issue/PAY-9/comment")
        let document = try #require(try body(request)["body"] as? [String: Any])
        #expect(document["type"] as? String == "doc" && document["version"] as? Int == 1)
        #expect(ADFText.plain(document) == "Shipped in 1.4.\n\nSee the MR.")
    }

    @Test func aBlankCommentOrAKeyThatIsNoKeyNeverReachesTheNetwork() async throws {
        let stub = StubSession { _ in (201, Data(#"{"id":"1"}"#.utf8)) }
        await #expect(throws: JiraError.refused(status: 400, detail: "A comment needs text.")) {
            _ = try await JiraClient(config: config, session: stub.session).comment(key: "PAY-9", body: " \n ")
        }
        await #expect(throws: JiraError.refused(status: 400, detail: "x isn’t a Jira ticket key.")) {
            _ = try await JiraClient(config: config, session: stub.session).comment(key: "x", body: "hi")
        }
        struct Paused: Error {}
        await #expect(throws: Paused.self) {
            _ = try await JiraClient(config: config, session: stub.session).comment(key: "PAY-9", body: "hi", beforeWrite: { throw Paused() })
        }
        #expect(stub.requests.isEmpty)
    }
}
