import Foundation

public struct JiraConfig: Equatable, Sendable { public let siteURL: URL, email: String, token: String
    public init(siteURL: URL, email: String, token: String) {
        self.siteURL = Self.normalizedSiteURL(siteURL); self.email = email; self.token = token
    }

    public static func normalizedSiteURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.password = nil
        components.user = nil
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        components.query = nil
        components.fragment = nil
        while components.path.count > 1 && components.path.hasSuffix("/") { components.path.removeLast() }
        if components.path == "/" { components.path = "" }
        return components.url ?? url
    }
}

public enum JiraError: Error, Equatable, LocalizedError {
    case unauthorized, network(String), badResponse(Int), decoding
    case projectSiteMismatch(linked: URL, configured: URL)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Check your Jira email and API token in Settings › Integrations."
        case .network(let message): return "Couldn’t connect to Jira. \(message)"
        case .badResponse(let status): return "Jira returned an error (HTTP \(status)). Try again."
        case .decoding: return "Couldn’t read Jira’s response. Try again."
        case .projectSiteMismatch(let linked, let configured):
            return "This project is linked to Jira at \(linked.absoluteString), but Settings is connected to \(configured.absoluteString). Remove it in Jira Projects… and link it again."
        }
    }
}

public struct JiraClient: Sendable {
    let config: JiraConfig, session: URLSession
    public init(config: JiraConfig, session: URLSession = .shared) { self.config = config; self.session = session }

    public static let openIssuesJQL = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"

    public func myOpenIssues(projects: [JiraProjectRef] = []) async throws -> [JiraTicket] {
        try await search(jql: Self.scoped(Self.openIssuesJQL, in: try projectScope(projects)))
    }

    /// A key (`SHOP-12`, `shop-1`) finds that ticket in any status, then open tickets whose key starts
    /// with it. A number, with projects linked, does the same for that number in each of them and
    /// adds the tickets whose text mentions it. Anything else, and a number with no project to key
    /// it to, is a text search of open tickets.
    public func search(text: String, projects: [JiraProjectRef] = []) async throws -> [JiraTicket] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = try projectScope(projects)
        let textJQL = Self.scoped("text ~ \"\(Self.textQuery(t))\" AND statusCategory != Done ORDER BY updated DESC", in: scope)
        let projectKeys = projects.map { $0.key.uppercased() }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if let key = Self.issueKey(t) {
            return try await searchKeys([key], scope: scope, projectKeys: projectKeys) { $0.hasPrefix(key) }
        }
        guard !projectKeys.isEmpty, t.range(of: #"^[0-9]+$"#, options: .regularExpression) != nil else {
            return try await search(jql: textJQL)
        }
        let number = Self.withoutLeadingZeros(Substring(t))
        async let byKey = searchKeys(projectKeys.map { "\($0)-\(number)" }, scope: scope, projectKeys: projectKeys) {
            Self.number(of: $0).hasPrefix(number)
        }
        async let byText = search(jql: textJQL)
        return Self.merged(try await byKey, try await byText)
    }

    /// `text` as an issue key, upper-cased and its number without leading zeros; nil if it is not
    /// one. Jira's default key format needs a project key of two characters or more.
    private static func issueKey(_ text: String) -> String? {
        let key = text.uppercased()
        guard key.range(of: #"^[A-Z][A-Z0-9_]+-[0-9]+$"#, options: .regularExpression) != nil,
              let separator = key.lastIndex(of: "-") else { return nil }
        return String(key[...separator]) + withoutLeadingZeros(key[key.index(after: separator)...])
    }

    private static func withoutLeadingZeros(_ digits: Substring) -> String {
        let trimmed = digits.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private static func number(of key: String) -> Substring {
        key.lastIndex(of: "-").map { key[key.index(after: $0)...] } ?? ""
    }

    /// `exact`, each looked up with `key =` so it is found in any status and under a key it moved
    /// from; then Jira's picker suggestions for each whose key satisfies `matching`, open only.
    /// JQL cannot use `~` on issue keys, and the picker leaves out description and status, so the
    /// suggestions' full fields come from a second search. The picker requests run side by side,
    /// with the exact lookups.
    private func searchKeys(_ exact: [String], scope: String, projectKeys: [String],
                            matching: @escaping @Sendable (String) -> Bool) async throws -> [JiraTicket] {
        async let found = lookUp(exact, jql: { "key = \"\($0)\"" }, scope: scope)
        let suggested = try await suggestions(for: exact, scope: scope, projectKeys: projectKeys, matching: matching)
            .filter { !exact.contains($0) }
        let open = try await tickets(Array(suggested.prefix(Self.maxResults)), scope: scope)
        return Self.merged(try await found, open)
    }

    /// The picker's suggested keys for each query, in its own order — most recently updated first —
    /// taken from each query in turn so one project's many matches do not crowd out another's.
    private func suggestions(for queries: [String], scope: String, projectKeys: [String],
                             matching: @escaping @Sendable (String) -> Bool) async throws -> [String] {
        let currentJQL = (scope.isEmpty ? "" : scope + " ") + "ORDER BY updated DESC"
        let lists = try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            for (index, query) in queries.enumerated() {
                group.addTask {
                    let obj = try await send(request(path: "/rest/api/3/issue/picker", queryItems: [
                        URLQueryItem(name: "query", value: query),
                        URLQueryItem(name: "currentJQL", value: currentJQL),
                        URLQueryItem(name: "showSubTasks", value: "true"),
                    ]))
                    guard let sections = obj["sections"] as? [[String: Any]] else { throw JiraError.decoding }
                    return (index, sections.flatMap { section -> [String] in
                        let issues = section["issues"] as? [[String: Any]] ?? []
                        // Current Search keeps to currentJQL; History does not, so it is filtered here.
                        let scoped = projectKeys.isEmpty || section["id"] as? String == "cs"
                        return issues.compactMap { issue in
                            guard let key = issue["key"] as? String, Self.issueKey(key) == key, matching(key),
                                  scoped || projectKeys.contains(String(key[..<key.lastIndex(of: "-")!])) else { return nil }
                            return key
                        }
                    })
                }
            }
            return try await group.reduce(into: Array(repeating: [String](), count: queries.count)) { $0[$1.0] = $1.1 }
        }
        var keys: [String] = []
        for rank in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where rank < list.count && !keys.contains(list[rank]) { keys.append(list[rank]) }
        }
        return keys
    }

    /// The open tickets among `keys`, in their order. Jira answers 400 for the whole `key in (…)`
    /// when one key no longer resolves; each is then looked up alone, so only that one is lost.
    private func tickets(_ keys: [String], scope: String) async throws -> [JiraTicket] {
        guard !keys.isEmpty else { return [] }
        let list = keys.map { "\"\($0)\"" }.joined(separator: ", ")
        let found: [JiraTicket]
        do { found = try await search(jql: Self.scoped("key in (\(list)) AND statusCategory != Done", in: scope)) }
        catch JiraError.badResponse(400) {
            found = try await lookUp(keys, jql: { "key = \"\($0)\" AND statusCategory != Done" }, scope: scope)
        }
        let byKey = Dictionary(found.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return keys.compactMap { byKey[$0] }
    }

    /// One search per key, side by side, in `keys` order; a key Jira cannot resolve (400) finds nothing.
    private func lookUp(_ keys: [String], jql: @escaping @Sendable (String) -> String, scope: String) async throws -> [JiraTicket] {
        try await withThrowingTaskGroup(of: (Int, [JiraTicket]).self) { group in
            for (index, key) in keys.enumerated() {
                group.addTask {
                    do { return (index, try await search(jql: Self.scoped(jql(key), in: scope))) }
                    catch JiraError.badResponse(400) { return (index, []) }
                }
            }
            return try await group.reduce(into: Array(repeating: [JiraTicket](), count: keys.count)) { $0[$1.0] = $1.1 }
        }.flatMap { $0 }
    }

    /// `lists` in order, each ticket once, at most `maxResults`.
    private static func merged(_ lists: [JiraTicket]...) -> [JiraTicket] {
        var seen = Set<String>()
        return Array(lists.joined().filter { seen.insert($0.key).inserted }.prefix(maxResults))
    }

    static let maxResults = 25

    /// Jira runs `text ~` through Lucene, where these are operators: a summary pasted as the query
    /// — `[Frontend] …`, `C++`, `fix: x` — made it answer 400 or search for something else.
    static let luceneOperators = Set(#"+-&|!(){}[]^~*?\/:"#)

    /// `text` as the inside of the JQL string literal `text ~ "…"`: each Lucene operator escaped
    /// with a backslash, then the literal's own escaping — which doubles that backslash.
    static func textQuery(_ text: String) -> String {
        let lucene = text.reduce(into: "") { out, character in
            if luceneOperators.contains(character) { out.append("\\") }
            out.append(character)
        }
        return lucene.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// All Jira projects visible to the configured account, in Jira's name order.
    public func projects() async throws -> [JiraProjectRef] {
        let pageSize = 100
        var startAt = 0
        var projects: [JiraProjectRef] = []
        while true {
            let obj = try await send(request(path: "/rest/api/3/project/search", queryItems: [
                URLQueryItem(name: "startAt", value: String(startAt)),
                URLQueryItem(name: "maxResults", value: String(pageSize)),
                URLQueryItem(name: "orderBy", value: "name"),
            ]))
            guard let values = obj["values"] as? [[String: Any]] else { throw JiraError.decoding }
            projects += values.compactMap { value in
                guard let id = value["id"] as? String, let key = value["key"] as? String,
                      let name = value["name"] as? String else { return nil }
                return JiraProjectRef(id: id, key: key, name: name, siteURL: config.siteURL)
            }
            startAt += values.count
            let isLast = obj["isLast"] as? Bool
            let total = obj["total"] as? Int
            if isLast == true || values.isEmpty || total.map({ startAt >= $0 }) == true
                || (isLast == nil && total == nil && values.count < pageSize) { break }
        }
        return projects
    }

    public func testConnection() async throws -> String {
        let obj = try await get("/rest/api/3/myself")
        return (obj["displayName"] as? String) ?? (obj["emailAddress"] as? String) ?? "connected"
    }

    func search(jql: String) async throws -> [JiraTicket] {
        var req = request(path: "/rest/api/3/search/jql"); req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["jql": jql, "maxResults": Self.maxResults, "fields": ["summary", "description", "status", "issuetype"]])
        let obj = try await send(req)
        guard let issues = obj["issues"] as? [[String: Any]] else { throw JiraError.decoding }
        return issues.compactMap { issue in
            guard let key = issue["key"] as? String, let f = issue["fields"] as? [String: Any], let summary = f["summary"] as? String else { return nil }
            let desc = ADFText.plain(f["description"])
            return JiraTicket(key: key, summary: summary, description: desc.isEmpty ? nil : desc,
                              issueType: (f["issuetype"] as? [String: Any])?["name"] as? String, status: (f["status"] as? [String: Any])?["name"] as? String,
                              url: config.siteURL.appendingPathComponent("browse/\(key)").absoluteString)
        }
    }

    /// `project in (…)` for `projects`, every one of which must be on the configured site; empty
    /// for none, which leaves a search unscoped: every project the account can see.
    private func projectScope(_ projects: [JiraProjectRef]) throws -> String {
        guard !projects.isEmpty else { return "" }
        for project in projects {
            let linkedSite = JiraConfig.normalizedSiteURL(project.siteURL)
            guard linkedSite == config.siteURL else {
                throw JiraError.projectSiteMismatch(linked: linkedSite, configured: config.siteURL)
            }
        }
        let keys = projects.map { project in
            "\"" + project.key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "project in (\(keys.joined(separator: ", ")))"
    }

    /// `jql` limited by `scope`, a `projectScope`.
    private static func scoped(_ jql: String, in scope: String) -> String {
        scope.isEmpty ? jql : scope + " AND " + jql
    }

    private func get(_ path: String) async throws -> [String: Any] { try await send(request(path: path)) }

    private func request(path: String, queryItems: [URLQueryItem] = []) -> URLRequest {
        let base = config.siteURL.appendingPathComponent(path)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        var req = URLRequest(url: components?.url ?? base)
        req.setValue("Basic " + Data("\(config.email):\(config.token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        return req
    }

    private func send(_ req: URLRequest) async throws -> [String: Any] {
        let data: Data
        do { (data, _) = try await HTTPJSON.send(req, session: session) }
        catch HTTPJSON.Failure.transport(let error) { throw JiraError.network(error.localizedDescription) }
        catch HTTPJSON.Failure.status(let status) {
            throw status == 401 || status == 403 ? JiraError.unauthorized : JiraError.badResponse(status)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw JiraError.decoding }
        return obj
    }
}
