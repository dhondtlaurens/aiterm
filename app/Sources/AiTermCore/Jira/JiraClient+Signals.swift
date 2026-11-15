import Foundation

public extension JiraClient {
    /// Unlike the picker search, a signal reads every page and rejects malformed entries as a
    /// partial read. The caller owns membership and cursor advancement across those pages.
    func search(jql: String, fields: [String], pageToken: String?) async throws -> JiraSearchPage {
        struct Body: Encodable { var jql: String; var maxResults = 100; var fields: [String]; var nextPageToken: String? }
        let path = "/rest/api/3/search/jql"
        let data = try await send(method: "POST", path: path, json: JSONEncoder().encode(Body(jql: jql, fields: fields, nextPageToken: pageToken)), write: false)
        let page = try decode(SignalSearchResponse.self, data: data, reading: path)
        let tickets = page.issues.compactMap(\.value).map { issue in
            let text = ADFText.plain(issue.fields.description)
            return JiraTicket(key: issue.key, summary: issue.fields.summary, description: text.isEmpty ? nil : text,
                              issueType: issue.fields.issuetype?.name, status: issue.fields.status?.name,
                              url: siteURL.appendingPathComponent("browse/\(issue.key)").absoluteString,
                              updated: issue.fields.updated.flatMap(Self.date), labels: issue.fields.labels ?? [],
                              project: issue.fields.project?.key, assignee: issue.fields.assignee?.accountId)
        }
        let last = page.isLast ?? (page.nextPageToken == nil)
        return JiraSearchPage(tickets: tickets, nextPageToken: page.nextPageToken, isLast: last,
                              complete: tickets.count == page.issues.count && (last || page.nextPageToken != nil))
    }

    /// A bounded, read-only person picker. Jira may withhold email addresses.
    func signalUsers(query: String = "", accountId: String? = nil) async throws -> [JiraUser] {
        struct Person: Decodable { var accountId: String; var displayName: String; var emailAddress: String? }
        let selector = accountId.map { URLQueryItem(name: "accountId", value: $0) }
            ?? URLQueryItem(name: "query", value: query)
        let people = try await decode([Lenient<Person>].self, request(path: "/rest/api/3/user/search", queryItems: [
            selector, URLQueryItem(name: "startAt", value: "0"), URLQueryItem(name: "maxResults", value: "50")]))
        return people.compactMap(\.value).map { JiraUser(accountId: $0.accountId, displayName: $0.displayName, email: $0.emailAddress) }
    }

    func labels() async throws -> [String] {
        try await signalValues(String.self, path: "/rest/api/3/label")
    }
    func statuses() async throws -> [JiraStatusRef] {
        try await signalValues(JiraStatusRef.self, path: "/rest/api/3/statuses/search")
    }
    func approximateCount(jql: String) async throws -> Int {
        struct Body: Encodable { var jql: String }
        struct Answer: Decodable { var count: Int }
        let path = "/rest/api/3/search/approximate-count"
        let data = try await send(method: "POST", path: path, json: JSONEncoder().encode(Body(jql: jql)), write: false)
        let value = try decode(Answer.self, data: data, reading: path).count
        guard value >= 0 else { throw JiraError.decoding }
        return value
    }

    private func signalValues<Value: Decodable & Sendable>(_ type: Value.Type, path: String) async throws -> [Value] {
        var values: [Value] = [], start = 0
        for _ in 0..<100 {
            let page = try await decode(SignalValuesPage<Value>.self, request(path: path, queryItems: [
                URLQueryItem(name: "startAt", value: String(start)), URLQueryItem(name: "maxResults", value: "100")]))
            values += page.values; start += page.values.count
            if page.isLast == true || page.total.map({ start >= $0 }) == true ||
                (page.isLast == nil && page.total == nil && page.values.count < 100) { return values }
            guard !page.values.isEmpty else { throw IncompleteRead(path) }
        }
        throw IncompleteRead(path)
    }
}

private struct SignalValuesPage<Value: Decodable>: Decodable {
    var values: [Value]
    var isLast: Bool?
    var total: Int?
}
private struct SignalSearchResponse: Decodable {
    struct Named: Decodable { var name: String? }
    struct Project: Decodable { var key: String? }
    struct Assignee: Decodable { var accountId: String? }
    struct Fields: Decodable {
        var summary: String
        var description: JSONValue?
        var issuetype: Named?, status: Named?, updated: String?, labels: [String]?, project: Project?, assignee: Assignee?
    }
    struct Issue: Decodable { var key: String; var fields: Fields }
    var issues: [Lenient<Issue>]
    var isLast: Bool?
    var nextPageToken: String?
}
