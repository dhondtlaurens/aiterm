import Foundation

public struct JiraQueryReader: SignalSourceReader {
    private let client: JiraClient
    private let conditions: JiraConditions
    private let now: @Sendable () -> Date
    public init(client: JiraClient, conditions: JiraConditions, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.conditions = conditions; self.now = now
    }
    public func poll(since: Date?, full: Bool) async throws -> SignalRead {
        let at = now()
        var query = JQL.compile(conditions)
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
            let page = try await client.search(jql: query, fields: ["summary", "description", "status", "issuetype", "updated", "labels", "project", "assignee"], pageToken: token)
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
