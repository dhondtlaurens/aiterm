import Foundation

public struct JiraQueryReader: SignalSourceReader {
    private let client: JiraClient
    private let jql: String
    private let now: @Sendable () -> Date
    public init(client: JiraClient, jql: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.jql = jql; self.now = now
    }
    /// JQL for the one ticket `key`, narrowed by `jql` when given. `jql` keeps its own `ORDER BY` outside the narrowing,
    /// as `JiraClient.confined` places it; an unbalanced query is sent as written, for Jira to refuse.
    public static func ticket(_ key: String, matching jql: String? = nil) -> String {
        let clause = "key = \"" + key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        guard let jql else { return clause }
        return JiraClient.confined(jql, to: clause) ?? clause + " AND (" + jql + ")"
    }
    public func poll(since: Date?, full: Bool) async throws -> SignalRead {
        let at = now()
        var query = jql
        // Jira enhanced search requires a bounded query. This covers its entire supported date
        // range for a signal saved with no conditions, before the sheet required one.
        if query.isEmpty { query = #"created >= "1970-01-01""# }
        if !full, let since {
            let minutes = max(2, Int(ceil(max(0, at.timeIntervalSince(since)) / 60)) + 2)
            guard let delta = JiraClient.confined(query, to: "updated >= -\(minutes)m") else { throw JiraError.unconfinedQuery }
            query = delta
        }
        var token: String?, tokens = Set<String>(), items: [SignalItem] = [], seen = Set<String>()
        for _ in 0..<100 {
            let page = try await client.search(jql: query, limit: 100, pageToken: token)
            for ticket in page.tickets where seen.insert(ticket.key).inserted {
                items.append(SignalItem(item: .ticket(site: client.siteURL.absoluteString, key: ticket.key), title: ticket.summary,
                                        description: ticket.description, ticket: ticket, updated: ticket.updated))
            }
            guard page.complete else { return SignalRead(items: items, complete: false, full: full) }
            if page.isLast { return SignalRead(items: items, complete: true, cursor: at, full: full) }
            guard let next = page.nextPageToken, tokens.insert(next).inserted else { return SignalRead(items: items, complete: false, full: full) }
            token = next
        }
        return SignalRead(items: items, complete: false, full: full)
    }
}
