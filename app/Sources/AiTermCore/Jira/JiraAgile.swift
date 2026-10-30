import Foundation

/// A Jira board of a project (`GET /rest/agile/1.0/board`): `type` is `scrum`, `kanban` or `simple`.
public struct JiraBoard: Equatable, Sendable {
    public let id: Int, name: String, type: String
    public init(id: Int, name: String, type: String) { self.id = id; self.name = name; self.type = type }
}

/// A sprint of a scrum board, as Jira dates it (ISO 8601 text); `boardId` is the board it was read from.
public struct JiraSprint: Equatable, Sendable {
    public let id: Int, name: String, state: String, startDate: String?, endDate: String?, boardId: Int
    public init(id: Int, name: String, state: String, startDate: String?, endDate: String?, boardId: Int) {
        self.id = id; self.name = name; self.state = state; self.startDate = startDate; self.endDate = endDate; self.boardId = boardId
    }
}

/// A column of a board and the names of the statuses that put a ticket in it.
public struct JiraColumn: Equatable, Sendable {
    public let name: String, statuses: [String]
    public init(name: String, statuses: [String]) { self.name = name; self.statuses = statuses }
}

/// Jira's boards and sprints, and the writes that put tickets in a sprint or back on the backlog (spec §L).
extension JiraClient {
    /// The most tickets Jira moves in one sprint or backlog request.
    public static let maxSprintTickets = 50

    /// The boards of the project `project`, by its key.
    public func boards(project: String) async throws -> [JiraBoard] {
        try await agilePages("/rest/agile/1.0/board", [URLQueryItem(name: "projectKeyOrId", value: project)], as: AgileBoard.self)
            .map { JiraBoard(id: $0.id, name: $0.name, type: $0.type) }
    }

    /// The active and future sprints of the scrum board `board`. A board that has no sprints (a kanban one) is Jira's 400.
    public func sprints(board: Int) async throws -> [JiraSprint] {
        try await agilePages("/rest/agile/1.0/board/\(board)/sprint", [URLQueryItem(name: "state", value: "active,future")], as: AgileSprint.self)
            .map { JiraSprint(id: $0.id, name: $0.name, state: $0.state, startDate: $0.startDate, endDate: $0.endDate, boardId: board) }
    }

    /// The columns of `board`, each with its statuses' names: the configuration lists their ids, which `/status` names.
    public func columns(board: Int) async throws -> [JiraColumn] {
        let columns = try await decode(BoardConfiguration.self, request(path: "/rest/agile/1.0/board/\(board)/configuration"))
            .columnConfig.columns.compactMap(\.value)
        guard columns.contains(where: { !$0.statuses.isEmpty }) else { return columns.map { JiraColumn(name: $0.name, statuses: []) } }
        let names = Dictionary(try await decode([Lenient<StatusName>].self, request(path: "/rest/api/3/status")).compactMap(\.value).map { ($0.id, $0.name) },
                               uniquingKeysWith: { first, _ in first })
        return columns.map { column in JiraColumn(name: column.name, statuses: column.statuses.compactMap(\.value).compactMap { names[$0.id] }) }
    }

    /// Puts `tickets` in the sprint `sprint`. `beforeWrite` runs right before the request, and its error stops it.
    public func addToSprint(_ sprint: Int, tickets: [String], beforeWrite: @Sendable () async throws -> Void = {}) async throws {
        try await moveTickets(tickets, to: "/rest/agile/1.0/sprint/\(sprint)/issue", beforeWrite: beforeWrite)
    }

    /// Takes `tickets` out of their sprints, back on their boards' backlogs. `beforeWrite` as `addToSprint`'s.
    public func moveToBacklog(tickets: [String], beforeWrite: @Sendable () async throws -> Void = {}) async throws {
        try await moveTickets(tickets, to: "/rest/agile/1.0/backlog/issue", beforeWrite: beforeWrite)
    }

    /// `{"issues": tickets}` posted to `path`, which answers 204. A ticket that is no key, none, or more than Jira takes
    /// is refused before anything is sent.
    private func moveTickets(_ tickets: [String], to path: String, beforeWrite: @Sendable () async throws -> Void) async throws {
        guard !tickets.isEmpty else { throw JiraError.refused(status: 400, detail: "No tickets to move.") }
        guard tickets.count <= Self.maxSprintTickets else {
            throw JiraError.refused(status: 400, detail: "Jira moves at most \(Self.maxSprintTickets) tickets at once, and \(tickets.count) were named.")
        }
        let keys = try tickets.map { try Self.validKey($0) }
        try await beforeWrite()
        _ = try await send(method: "POST", path: path, json: JSONEncoder().encode(["issues": keys]))
    }

    /// Every entry of a paged agile list, a page at a time, the ones that do not read dropped alone.
    private func agilePages<Item: Decodable & Sendable>(_ path: String, _ query: [URLQueryItem], as: Item.Type) async throws -> [Item] {
        try await startAtPages { startAt in
            let page = try await decode(AgilePage<Item>.self, request(path: path, queryItems: query + (startAt == 0 ? [] : [URLQueryItem(name: "startAt", value: String(startAt))])))
            // Jira says when the last page came; a list that does not say is taken as whole.
            return (page.values.compactMap(\.value), page.values.count, page.isLast == false)
        }
    }
}

/// A page of an agile list. `values` keeps its malformed entries as empty ones, so `startAt` advances past them.
private struct AgilePage<Item: Decodable>: Decodable {
    var values: [Lenient<Item>]
    @Lenient var isLast: Bool?
}

private struct AgileBoard: Decodable, Sendable { var id: Int, name: String, type: String }

private struct AgileSprint: Decodable, Sendable {
    var id: Int, name: String, state: String
    @Lenient var startDate: String?
    @Lenient var endDate: String?
}

/// `/board/{id}/configuration`: its columns, each with the ids of its statuses; one that is not one drops alone.
private struct BoardConfiguration: Decodable {
    struct Column: Decodable {
        struct Status: Decodable { var id: String }
        var name: String, statuses: [Lenient<Status>]
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Key.self)
            name = try fields.decode(String.self, forKey: .name)
            statuses = fields.lenient([Lenient<Status>].self, forKey: .statuses) ?? []
        }
        private enum Key: String, CodingKey { case name, statuses }
    }
    struct Columns: Decodable { var columns: [Lenient<Column>] }
    var columnConfig: Columns
}

private struct StatusName: Decodable { var id: String, name: String }
