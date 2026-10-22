import Foundation

/// A person Jira can assign a ticket to.
public struct JiraUser: Equatable, Sendable {
    public let accountId: String, displayName: String, email: String?
    public init(accountId: String, displayName: String, email: String?) { self.accountId = accountId; self.displayName = displayName; self.email = email }
}

/// Who an edit assigns the ticket to. `unassigned` is Jira's `{"accountId": null}`; it is not called `none`, which
/// `JiraEdit.assignee`'s optional would read as no change.
public enum JiraAssignee: Equatable, Sendable {
    case me, unassigned
    /// A name or an email, which must match exactly one assignable user.
    case query(String)
}

/// What `jira_edit` changes (spec §L); a field left nil, or a list left empty, stays as it is. `fixVersions` is the
/// whole list the ticket ends with, so an empty one clears them; an empty `description` clears it too.
public struct JiraEdit: Equatable, Sendable {
    public var summary: String?, description: String?
    public var labelsAdd: [String], labelsRemove: [String]
    public var priority: String?
    public var fixVersions: [String]?
    public var assignee: JiraAssignee?
    public init(summary: String? = nil, description: String? = nil, labelsAdd: [String] = [], labelsRemove: [String] = [],
                priority: String? = nil, fixVersions: [String]? = nil, assignee: JiraAssignee? = nil) {
        self.summary = summary; self.description = description; self.labelsAdd = labelsAdd; self.labelsRemove = labelsRemove
        self.priority = priority; self.fixVersions = fixVersions; self.assignee = assignee
    }
    public var isEmpty: Bool { self == JiraEdit() }
}

/// The Jira writes behind the Operator's Jira slice (spec §5, §L): create a ticket, move it, link two, edit one, and
/// comment on one.
extension JiraClient {
    /// A ticket of `type` in `project`, its `description` in ADF, under `parent` when it is a sub-task or
    /// belongs to an epic; its key.
    public func createIssue(project: String, type: String, summary: String, description: String, parent: String? = nil,
                            labels: [String] = []) async throws -> String {
        var fields: [String: Any] = ["project": ["key": project], "issuetype": ["name": type], "summary": summary]
        if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields["description"] = ADFText.document(description) }
        if let parent { fields["parent"] = ["key": parent] }
        if !labels.isEmpty { fields["labels"] = labels }
        var req = request(path: "/rest/api/3/issue"); req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])
        return try await writeDecode(Created.self, req).key
    }

    /// Moves `key` to the status named `statusName`: false, with nothing made, when it is in that status already; else
    /// Jira's transitions for it are read, and the one whose target status has that name (case aside) is made. A ticket
    /// with no such way from where it is stays as it was.
    @discardableResult
    public func transition(key: String, to statusName: String, beforeWrite: @Sendable () async throws -> Void = {}) async throws -> Bool {
        let path = "/rest/api/3/issue/\(try Self.validKey(key))/transitions"
        let current = try await writeDecode(Current.self, request(path: "/rest/api/3/issue/\(key)", queryItems: [URLQueryItem(name: "fields", value: "status")]))
        if current.fields.status?.value?.name?.caseInsensitiveCompare(statusName) == .orderedSame { return false }
        let offered = try await writeDecode(Transitions.self, request(path: path)).transitions.compactMap(\.value)
        guard let chosen = offered.first(where: { $0.to?.value?.name?.caseInsensitiveCompare(statusName) == .orderedSame }) else {
            throw JiraError.noTransition(key: key, status: statusName, offered: offered.compactMap { $0.to?.value?.name })
        }
        try await beforeWrite()
        var req = request(path: path); req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["transition": ["id": chosen.id]])
        try await perform(req)
        return true
    }

    /// `key` linked to `other` by the link type named `type` (`Blocks`, `Relates`, `Duplicate`), read from `key`'s
    /// side: "`key` blocks `other`".
    public func link(key: String, to other: String, type: String) async throws {
        var req = request(path: "/rest/api/3/issueLink"); req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "type": ["name": type], "outwardIssue": ["key": try Self.validKey(key)], "inwardIssue": ["key": try Self.validKey(other)],
        ])
        try await perform(req)
    }

    /// Changes the fields of `key` that `fields` names, with `PUT /rest/api/3/issue/{key}`. The labels go as add and remove
    /// operations, so the ticket's others stay. An assignee is looked up first (`me` through `/myself`, a name through
    /// the project's assignable users, which must name exactly one); `beforeWrite` runs after that, right before the
    /// request, and its error stops it.
    public func edit(key: String, fields: JiraEdit, beforeWrite: @Sendable () async throws -> Void = {}) async throws {
        let path = "/rest/api/3/issue/\(try Self.validKey(key))"
        guard !fields.isEmpty else { throw JiraError.refused(status: 400, detail: "An edit needs at least one field to change.") }
        var sent: [String: Any] = [:], update: [String: Any] = [:]
        if let summary = fields.summary { sent["summary"] = summary }
        if let description = fields.description {
            sent["description"] = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : ADFText.document(description)
        }
        if let priority = fields.priority { sent["priority"] = ["name": priority] }
        if let versions = fields.fixVersions { sent["fixVersions"] = versions.map { ["name": $0] } }
        let labels = fields.labelsAdd.map { ["add": $0] } + fields.labelsRemove.map { ["remove": $0] }
        if !labels.isEmpty { update["labels"] = labels }
        switch fields.assignee {
        case nil: break
        case .unassigned: sent["assignee"] = ["accountId": NSNull()]
        case .me: sent["assignee"] = ["accountId": try await decode(Account.self, request(path: "/rest/api/3/myself")).accountId]
        case .query(let query): sent["assignee"] = ["accountId": try await assignee(matching: query, forTicket: key).accountId]
        }
        try await beforeWrite()
        var req = request(path: path); req.httpMethod = "PUT"
        req.httpBody = try JSONSerialization.data(withJSONObject: update.isEmpty ? ["fields": sent] : ["fields": sent, "update": update])
        try await perform(req)
    }

    /// The users of `project` a ticket can be assigned to whose name or email matches `query`.
    public func assignable(project: String, query: String) async throws -> [JiraUser] {
        try await decode([Lenient<AssignableUser>].self, request(path: "/rest/api/3/user/assignable/search", queryItems: [
            URLQueryItem(name: "project", value: project), URLQueryItem(name: "query", value: query),
        ])).compactMap(\.value).map { JiraUser(accountId: $0.accountId, displayName: $0.displayName, email: $0.emailAddress) }
    }

    /// The one assignable user of `ticket`'s project that `query` matches; no one, or several, is Jira's 400 in our words,
    /// the several named so the caller can say which.
    private func assignee(matching query: String, forTicket ticket: String) async throws -> JiraUser {
        let project = String(ticket.prefix { $0 != "-" })
        let users = try await assignable(project: project, query: query)
        if users.count == 1, let only = users.first { return only }
        // Jira's search is by substring: a query that is exactly one user's email or name picks that user.
        let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = users.filter { $0.email?.caseInsensitiveCompare(wanted) == .orderedSame || $0.displayName.caseInsensitiveCompare(wanted) == .orderedSame }
        if exact.count == 1, let only = exact.first { return only }
        guard !users.isEmpty else { throw JiraError.refused(status: 400, detail: "No assignable user in \(project) matches “\(query)”.") }
        let named = users.prefix(5).map { user in user.email.map { "\(user.displayName) (\($0))" } ?? user.displayName }.joined(separator: ", ")
        throw JiraError.refused(status: 400, detail: "“\(query)” matches more than one assignable user: \(named)\(users.count > 5 ? ", …" : ""). Use a fuller name or an email.")
    }

    /// The comment property that tags a comment with the call that made it: `findComment` reads it back.
    static let commentPropertyKey = "aiterm"

    /// Comments `body`, in ADF, on `key`; the comment's id. A `tag` is set on the comment as a property, so a call whose
    /// answer was lost can find what it posted (`findComment`). `beforeWrite` is as `edit`'s.
    public func comment(key: String, body: String, tag: String? = nil, beforeWrite: @Sendable () async throws -> Void = {}) async throws -> String {
        let path = "/rest/api/3/issue/\(try Self.validKey(key))/comment"
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw JiraError.refused(status: 400, detail: "A comment needs text.") }
        try await beforeWrite()
        var sent: [String: Any] = ["body": ADFText.document(body)]
        if let tag { sent["properties"] = [["key": Self.commentPropertyKey, "value": ["call": tag]]] }
        var req = request(path: path); req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: sent)
        return try await writeDecode(CommentCreated.self, req).id
    }

    /// The id of the comment on `key` that carries `tag` (set by `comment`), nil when there is none. A read, a page of
    /// comments at a time.
    public func findComment(key: String, tag: String) async throws -> String? {
        let path = "/rest/api/3/issue/\(try Self.validKey(key))/comment"
        var startAt = 0
        for _ in 0..<20 {
            let page = try await decode(CommentPage.self, request(path: path, queryItems: [
                URLQueryItem(name: "expand", value: "properties"), URLQueryItem(name: "startAt", value: String(startAt)),
                URLQueryItem(name: "maxResults", value: "100"),
            ]))
            let comments = page.comments.compactMap(\.value)
            if let found = comments.first(where: { $0.tags.contains(tag) }) { return found.id }
            startAt += page.comments.count
            if page.comments.isEmpty || startAt >= (page.total ?? startAt) { break }
        }
        return nil
    }

    /// A write whose answer is an empty 2xx (a transition and a link answer 204).
    func perform(_ request: URLRequest) async throws { _ = try await writeSend(request) }

    private func writeDecode<Response: Decodable>(_ type: Response.Type, _ request: URLRequest) async throws -> Response {
        let data = try await writeSend(request)
        do { return try JSONDecoder().decode(type, from: data) } catch { throw JiraError.decoding }
    }

    /// The request's answer body. A refusal keeps Jira's own words: its 400s and 404s say which field or which
    /// ticket, which is what the Operator needs to correct the call.
    private func writeSend(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await HTTPJSON.sendUnchecked(request, session: session)
            guard (200..<300).contains(response.statusCode) else { throw Self.writeError(status: response.statusCode, body: data) }
            return data
        } catch let failure as HTTPJSON.Failure { throw Self.error(for: failure) }
    }

    static func writeError(status: Int, body: Data) -> JiraError {
        switch status {
        case 401, 403: return .unauthorized
        case 429, 500...: return .badResponse(status)
        default: return .refused(status: status, detail: excerpt(of: body))
        }
    }

    /// Jira's `errorMessages` and `errors` values joined, at most 300 characters; empty when the body is neither.
    static func excerpt(of body: Data) -> String {
        guard let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "" }
        let messages = (fields["errorMessages"] as? [Any] ?? []).compactMap { $0 as? String }
        let errors = (fields["errors"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }.compactMap { name, value in
            (value as? String).map { "\(name): \($0)" }
        }
        let joined = (messages + errors).joined(separator: "; ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.count > 300 ? String(joined.prefix(299)) + "…" : joined
    }

    /// `key` when it is an issue key, so it is safe as a path segment; a Jira 400 says what the caller sent was no ticket.
    static func validKey(_ key: String) throws -> String {
        guard key.range(of: #"^[A-Za-z][A-Za-z0-9_]+-[0-9]+$"#, options: .regularExpression) != nil else { throw JiraError.refused(status: 400, detail: "\(key) isn’t a Jira ticket key.") }
        return key
    }
}

private struct Created: Decodable { var key: String }
private struct CommentCreated: Decodable { var id: String }
private struct Account: Decodable { var accountId: String }

/// `/issue/{key}/comment?expand=properties`: a page of comments, each with the `call` tags of its `aiterm` properties.
private struct CommentPage: Decodable {
    struct Comment: Decodable {
        struct Property: Decodable {
            struct Value: Decodable { var call: String? }
            var key: String, value: Lenient<Value>?
        }
        var id: String, properties: [Lenient<Property>]
        var tags: [String] { properties.compactMap(\.value).filter { $0.key == JiraClient.commentPropertyKey }.compactMap { $0.value?.value?.call } }
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Key.self)
            id = try fields.decode(String.self, forKey: .id)
            properties = fields.lenient([Lenient<Property>].self, forKey: .properties) ?? []
        }
        private enum Key: String, CodingKey { case id, properties }
    }
    var comments: [Lenient<Comment>], total: Int?
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        comments = try fields.decode([Lenient<Comment>].self, forKey: .comments)
        total = fields.lenient(Int.self, forKey: .total)
    }
    private enum Key: String, CodingKey { case comments, total }
}

/// `/user/assignable/search`: one entry; one that is not one drops alone.
private struct AssignableUser: Decodable {
    var accountId: String, displayName: String, emailAddress: String?
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        accountId = try fields.decode(String.self, forKey: .accountId)
        displayName = fields.lenient(String.self, forKey: .displayName) ?? accountId
        emailAddress = fields.lenient(String.self, forKey: .emailAddress)
    }
    private enum Key: String, CodingKey { case accountId, displayName, emailAddress }
}

/// `/issue/{key}?fields=status`: the status it is in.
private struct Current: Decodable {
    struct Status: Decodable { var name: String? }
    struct Fields: Decodable { var status: Lenient<Status>? }
    var fields: Fields
}

/// `/issue/{key}/transitions`: the moves it has; one that is not one drops alone.
private struct Transitions: Decodable {
    struct Move: Decodable {
        struct Status: Decodable { var name: String? }
        var id: String, to: Lenient<Status>?
    }
    var transitions: [Lenient<Move>]
}

extension ADFText {
    /// `text` as an Atlassian Document Format document: a paragraph for each run of lines, its line breaks kept.
    static func document(_ text: String) -> [String: Any] {
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return ["type": "doc", "version": 1, "content": paragraphs.map { paragraph -> [String: Any] in
            let lines = paragraph.components(separatedBy: "\n")
            let inline = lines.enumerated().flatMap { index, line -> [[String: Any]] in
                (index > 0 ? [["type": "hardBreak"]] : []) + (line.isEmpty ? [] : [["type": "text", "text": line]])
            }
            return ["type": "paragraph", "content": inline]
        }]
    }
}
