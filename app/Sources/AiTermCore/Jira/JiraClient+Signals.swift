import Foundation

public extension JiraClient {
    /// The site's labels, or its first `limit` of them.
    func labels(limit: Int? = nil) async throws -> [String] {
        try await signalValues(String.self, path: "/rest/api/3/label", limit: limit)
    }
    /// The site's statuses, or its first `limit` of them.
    func statuses(limit: Int? = nil) async throws -> [JiraStatusRef] {
        try await signalValues(JiraStatusRef.self, path: "/rest/api/3/statuses/search", limit: limit)
    }
    /// What Jira finds wrong with `jql`, in its own words; empty when it would run. Strict, so an unknown field, value or
    /// function counts as wrong.
    func jqlErrors(_ jql: String) async throws -> [String] {
        struct Body: Encodable { var queries: [String] }
        struct Answer: Decodable {
            struct Parsed: Decodable { var errors: [String]? }
            var queries: [Parsed]
        }
        let path = "/rest/api/3/jql/parse"
        var request = request(path: path, queryItems: [URLQueryItem(name: "validation", value: "strict")])
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(Body(queries: [jql]))
        let data: Data
        do { data = try await HTTPJSON.send(request, session: session).0 }
        catch let failure as HTTPJSON.Failure { throw Self.error(for: failure) }
        guard let parsed = try decode(Answer.self, data: data, reading: path).queries.first else { throw JiraError.decoding }
        return parsed.errors ?? []
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

    private func signalValues<Value: Decodable & Sendable>(_ type: Value.Type, path: String, limit: Int?) async throws -> [Value] {
        var values: [Value] = [], start = 0
        for _ in 0..<100 {
            let page = try await decode(SignalValuesPage<Value>.self, request(path: path, queryItems: [
                URLQueryItem(name: "startAt", value: String(start)), URLQueryItem(name: "maxResults", value: "100")]))
            values += page.values; start += page.values.count
            if let limit, values.count >= limit { return Array(values.prefix(limit)) }
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
