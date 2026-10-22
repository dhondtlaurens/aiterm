import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

/// Jira's boards, sprints and columns, and the sprint writes (spec §L): `jira_board` and `jira_sprint`.
@Suite struct JiraAgileTests {
    let config = JiraConfig(siteURL: URL(string: "https://example.atlassian.net")!, email: "me@example.com", token: "tok")

    func body(_ request: URLRequest?) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request?.httpBody ?? Data()) as? [String: Any])
    }

    /// A line for each request: its method, path and query.
    func lines(_ stub: StubSession) -> [String] {
        stub.requests.map { ($0.httpMethod ?? "GET") + " " + ($0.url?.path ?? "") + ($0.url?.query.map { "?" + $0 } ?? "") }
    }

    @Test func boardsSprintsAndColumnsAreRead() async throws {
        let stub = StubSession { request in
            switch request.url?.path ?? "" {
            case "/rest/agile/1.0/board":
                return (200, Data(#"{"isLast":true,"values":[{"id":7,"name":"FE board","type":"scrum"},{"id":8,"name":"FE flow","type":"kanban"},{"nope":1}]}"#.utf8))
            case "/rest/agile/1.0/board/7/sprint":
                return (200, Data(#"{"isLast":true,"values":[{"id":41,"name":"Sprint 41","state":"active","startDate":"2026-10-12T08:00:00.000Z","endDate":"2026-10-26T08:00:00.000Z","originBoardId":7},{"id":42,"name":"Sprint 42","state":"future"}]}"#.utf8))
            case "/rest/agile/1.0/board/7/configuration":
                return (200, Data(#"{"columnConfig":{"columns":[{"name":"To Do","statuses":[{"id":"1"}]},{"name":"Doing","statuses":[{"id":"3"},{"id":"4"}]},{"name":"Done","statuses":[]}]}}"#.utf8))
            case "/rest/api/3/status":
                return (200, Data(#"[{"id":"1","name":"Open"},{"id":"3","name":"In Progress"},{"id":"4","name":"In Review"},{"id":"9","name":"Unused"}]"#.utf8))
            default: return (404, Data())
            }
        }
        let client = JiraClient(config: config, session: stub.session)
        let boards = try await client.boards(project: "FE")
        #expect(boards == [JiraBoard(id: 7, name: "FE board", type: "scrum"), JiraBoard(id: 8, name: "FE flow", type: "kanban")], "an entry that is no board drops alone")
        let sprints = try await client.sprints(board: 7)
        #expect(sprints == [JiraSprint(id: 41, name: "Sprint 41", state: "active", startDate: "2026-10-12T08:00:00.000Z", endDate: "2026-10-26T08:00:00.000Z", boardId: 7),
                            JiraSprint(id: 42, name: "Sprint 42", state: "future", startDate: nil, endDate: nil, boardId: 7)])
        let columns = try await client.columns(board: 7)
        #expect(columns == [JiraColumn(name: "To Do", statuses: ["Open"]), JiraColumn(name: "Doing", statuses: ["In Progress", "In Review"]),
                            JiraColumn(name: "Done", statuses: [])])
        #expect(lines(stub) == ["GET /rest/agile/1.0/board?projectKeyOrId=FE",
                                "GET /rest/agile/1.0/board/7/sprint?state=active,future",
                                "GET /rest/agile/1.0/board/7/configuration", "GET /rest/api/3/status"])
        #expect(stub.lastRequest?.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
    }

    @Test func aBoardWithNoColumnStatusesReadsNoStatusList() async throws {
        let stub = StubSession { _ in (200, Data(#"{"columnConfig":{"columns":[{"name":"Done","statuses":[]}]}}"#.utf8)) }
        let columns = try await JiraClient(config: config, session: stub.session).columns(board: 7)
        #expect(columns == [JiraColumn(name: "Done", statuses: [])])
        #expect(lines(stub) == ["GET /rest/agile/1.0/board/7/configuration"])
    }

    @Test func morePagesAreRead() async throws {
        let stub = StubSession { request in
            request.url?.query?.contains("startAt=1") == true
                ? (200, Data(#"{"isLast":true,"values":[{"id":2,"name":"B","type":"scrum"}]}"#.utf8))
                : (200, Data(#"{"isLast":false,"values":[{"id":1,"name":"A","type":"scrum"}]}"#.utf8))
        }
        let boards = try await JiraClient(config: config, session: stub.session).boards(project: "FE")
        #expect(boards.map(\.id) == [1, 2])
        #expect(lines(stub) == ["GET /rest/agile/1.0/board?projectKeyOrId=FE", "GET /rest/agile/1.0/board?projectKeyOrId=FE&startAt=1"])
    }

    @Test func aTicketIsAddedToASprint() async throws {
        let stub = StubSession { _ in (204, Data()) }
        try await JiraClient(config: config, session: stub.session).addToSprint(41, tickets: ["FE-1"])
        let request = try #require(stub.lastRequest)
        #expect(request.httpMethod == "POST" && request.url?.path == "/rest/agile/1.0/sprint/41/issue")
        #expect(String(data: try #require(request.httpBody), encoding: .utf8) == #"{"issues":["FE-1"]}"#)
    }

    @Test func toTheBacklog() async throws {
        let stub = StubSession { _ in (204, Data()) }
        try await JiraClient(config: config, session: stub.session).moveToBacklog(tickets: ["FE-1", "FE-2"])
        let request = try #require(stub.lastRequest)
        #expect(request.httpMethod == "POST" && request.url?.path == "/rest/agile/1.0/backlog/issue")
        #expect(String(data: try #require(request.httpBody), encoding: .utf8) == #"{"issues":["FE-1","FE-2"]}"#)
    }

    @Test func aSprintWriteStopsWhenItsLastCheckRefuses() async throws {
        struct Paused: Error {}
        let stub = StubSession { _ in (204, Data()) }
        await #expect(throws: Paused.self) {
            try await JiraClient(config: config, session: stub.session).addToSprint(41, tickets: ["FE-1"], beforeWrite: { throw Paused() })
        }
        await #expect(throws: Paused.self) {
            try await JiraClient(config: config, session: stub.session).moveToBacklog(tickets: ["FE-1"], beforeWrite: { throw Paused() })
        }
        #expect(stub.requests.isEmpty)
    }

    @Test func noTicketsAndAKeyThatIsNoKeyNeverReachTheNetwork() async throws {
        let stub = StubSession { _ in (204, Data()) }
        let client = JiraClient(config: config, session: stub.session)
        await #expect(throws: JiraError.refused(status: 400, detail: "FE-1/../x isn’t a Jira ticket key.")) { try await client.addToSprint(41, tickets: ["FE-1/../x"]) }
        await #expect(throws: JiraError.refused(status: 400, detail: "No tickets to move.")) { try await client.moveToBacklog(tickets: []) }
        let many = (1...51).map { "FE-\($0)" }
        await #expect(throws: JiraError.refused(status: 400, detail: "Jira moves at most 50 tickets at once, and 51 were named.")) { try await client.addToSprint(41, tickets: many) }
        #expect(stub.requests.isEmpty)
    }

    @Test func errorsAreMappedAsTheOtherWritesAre() async throws {
        for (status, expected) in [(401, JiraError.unauthorized), (403, .unauthorized), (429, .badResponse(429)), (500, .badResponse(500)),
                                   (400, .refused(status: 400, detail: "Sprint 41 is closed."))] {
            let stub = StubSession { _ in (status, Data(#"{"errorMessages":["Sprint 41 is closed."]}"#.utf8)) }
            await #expect(throws: expected) { try await JiraClient(config: config, session: stub.session).addToSprint(41, tickets: ["FE-1"]) }
            await #expect(throws: expected) { try await JiraClient(config: config, session: stub.session).moveToBacklog(tickets: ["FE-1"]) }
        }
    }
}
