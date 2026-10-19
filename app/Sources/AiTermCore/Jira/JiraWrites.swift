import Foundation

/// The Jira writes behind the Operator's Jira slice (spec §5): create a ticket, move it, link two.
/// Comments are not here: a comment messages people.
extension JiraClient {
    /// A ticket of `type` in `project`, its `description` in ADF, under `parent` when it is a sub-task or
    /// belongs to an epic; its key.
    public func createIssue(project: String, type: String, summary: String, description: String, parent: String? = nil) async throws -> String {
        var fields: [String: Any] = ["project": ["key": project], "issuetype": ["name": type], "summary": summary]
        if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields["description"] = ADFText.document(description) }
        if let parent { fields["parent"] = ["key": parent] }
        var req = request(path: "/rest/api/3/issue"); req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])
        return try await writeDecode(Created.self, req).key
    }

    /// Moves `key` to the status named `statusName`: false, with nothing made, when it is in that status already; else
    /// Jira's transitions for it are read, and the one whose target status has that name (case aside) is made. A ticket
    /// with no such way from where it is stays as it was.
    @discardableResult
    public func transition(key: String, to statusName: String) async throws -> Bool {
        let path = "/rest/api/3/issue/\(try Self.validKey(key))/transitions"
        let current = try await writeDecode(Current.self, request(path: "/rest/api/3/issue/\(key)", queryItems: [URLQueryItem(name: "fields", value: "status")]))
        if current.fields.status?.value?.name?.caseInsensitiveCompare(statusName) == .orderedSame { return false }
        let offered = try await writeDecode(Transitions.self, request(path: path)).transitions.compactMap(\.value)
        guard let chosen = offered.first(where: { $0.to?.value?.name?.caseInsensitiveCompare(statusName) == .orderedSame }) else {
            throw JiraError.noTransition(key: key, status: statusName, offered: offered.compactMap { $0.to?.value?.name })
        }
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

    /// A write whose answer is an empty 2xx (a transition and a link answer 204).
    private func perform(_ request: URLRequest) async throws { _ = try await writeSend(request) }

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
    private static func validKey(_ key: String) throws -> String {
        guard key.range(of: #"^[A-Za-z][A-Za-z0-9_]+-[0-9]+$"#, options: .regularExpression) != nil else { throw JiraError.refused(status: 400, detail: "\(key) isn’t a Jira ticket key.") }
        return key
    }
}

private struct Created: Decodable { var key: String }

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
