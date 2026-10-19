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
        return try await decode(Created.self, req).key
    }

    /// Moves `key` to the status named `statusName`: Jira's transitions for it are read, and the one whose target
    /// status has that name (case aside) is made. A ticket with no such way from where it is stays as it was.
    public func transition(key: String, to statusName: String) async throws {
        let path = "/rest/api/3/issue/\(try Self.validKey(key))/transitions"
        let offered = try await decode(Transitions.self, request(path: path)).transitions.compactMap(\.value)
        guard let chosen = offered.first(where: { $0.to?.value?.name?.caseInsensitiveCompare(statusName) == .orderedSame }) else {
            throw JiraError.noTransition(key: key, status: statusName, offered: offered.compactMap { $0.to?.value?.name })
        }
        var req = request(path: path); req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["transition": ["id": chosen.id]])
        try await perform(req)
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
    private func perform(_ request: URLRequest) async throws {
        do { _ = try await HTTPJSON.send(request, session: session) }
        catch let failure as HTTPJSON.Failure { throw Self.error(for: failure) }
    }

    /// `key` when it is an issue key, so it is safe as a path segment; a Jira 400 says what the caller sent was no ticket.
    private static func validKey(_ key: String) throws -> String {
        guard key.range(of: #"^[A-Za-z][A-Za-z0-9_]+-[0-9]+$"#, options: .regularExpression) != nil else { throw JiraError.badResponse(400) }
        return key
    }
}

private struct Created: Decodable { var key: String }

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
