import Foundation

/// A person returned by Jira's Signal person picker.
public struct JiraUser: Equatable, Sendable {
    public let accountId: String, displayName: String, email: String?
    public init(accountId: String, displayName: String, email: String?) { self.accountId = accountId; self.displayName = displayName; self.email = email }
}

public extension JiraClient {
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
        let data = try await send(method: "POST", path: path, json: JSONEncoder().encode(Body(jql: jql)))
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
            if page.isLast { return values }
            guard !page.values.isEmpty else { throw IncompleteRead(path) }
        }
        throw IncompleteRead(path)
    }
}

private struct SignalValuesPage<Value: Decodable>: Decodable {
    var values: [Value]
    var isLast: Bool
}
