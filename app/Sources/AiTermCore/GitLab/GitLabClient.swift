import Foundation

public struct GitLabConfig: Equatable, Sendable {
    public var hostURL: URL, token: String
    public init(hostURL: URL, token: String) { self.hostURL = hostURL; self.token = token }
}

public struct MergeRequest: Equatable, Sendable, Identifiable {
    public var iid: Int, title: String, sourceBranch: String, targetBranch: String
    public var author: String?, state: String, draft: Bool, url: String
    /// `owner:branch` when the branch lives in a fork rather than on origin, which is where a
    /// review checks out from. Only GitHub reports it.
    public var forkHead: String?
    public var id: Int { iid }
    public init(iid: Int, title: String, sourceBranch: String, targetBranch: String,
                author: String?, state: String, draft: Bool, url: String, forkHead: String? = nil) {
        self.iid = iid; self.title = title; self.sourceBranch = sourceBranch; self.targetBranch = targetBranch
        self.author = author; self.state = state; self.draft = draft; self.url = url; self.forkHead = forkHead
    }

    /// The lane a picked merge or pull request shows beside its title.
    public var lane: String { forkHead != nil ? "Fork" : draft ? "Draft" : state.capitalized }
    public var host: CodeHost { CodeHost(webURL: url) }
    /// `!87` for GitLab, `#87` for GitHub.
    public var reference: String { host.reference(iid) }
}

public enum GitLabError: Error, Equatable, LocalizedError {
    case unauthorized, network(String), badResponse(Int), decoding, projectNotFound(String)
    /// Nothing at the host answers GitLab's API — a mistyped host, or a web page in front of it.
    case noAPI(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Check your GitLab access token in Settings › Integrations."
        case .network(let message): return "Couldn’t connect to GitLab. \(message)"
        case .badResponse(let status): return "GitLab returned an error (HTTP \(status)). Try again."
        case .decoding: return "Couldn’t read GitLab’s response. Try again."
        // A valid token that cannot see a project is a different instruction from a bad token.
        case .projectNotFound(let path): return "GitLab has no project at \(path), or your token cannot see it."
        case .noAPI(let host): return "GitLab’s API was not found at \(host). Check the host URL in Settings › Integrations."
        }
    }
}

public struct GitLabClient: Sendable {
    let config: GitLabConfig, session: URLSession
    public init(config: GitLabConfig, session: URLSession = .shared) { self.config = config; self.session = session }

    /// A GitLab project id is the namespaced path as **one** path segment, so every `/` inside it
    /// must be escaped. `.urlPathAllowed` leaves `/` alone, which would split `a/b/c` into three
    /// segments and 404 on every subgroup project.
    public static func encodedProject(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    /// `path` on the GitLab at `host`, whose trailing slashes are dropped. `path` already carries
    /// its percent-encoding. `URLComponents(string:)` keeps `percentEncodedPath` verbatim and
    /// setting `queryItems` does not touch it, so the project's `%2F` survives — which assigning
    /// to `components.path` would not (it re-escapes the `%`).
    static func apiURL(host: URL, path: String, query: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(string: base(host) + path) else { return nil }
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    /// The host as written in Settings, less its trailing slashes.
    static func base(_ host: URL) -> String {
        var base = host.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// GitLab's payloads are snake_case.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    public func testConnection() async throws -> String {
        struct User: Decodable { var username: String }
        return try await get(User.self, path: "/api/v4/user", notFound: .noAPI(Self.base(config.hostURL))).username
    }

    public func mergeRequests(project: String, search: String) async throws -> [MergeRequest] {
        let base = "/api/v4/projects/" + Self.encodedProject(project) + "/merge_requests"
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)

        // Typing a merge request's number finds that merge request, rather than full-text
        // searching for the digits — the analogue of JiraClient's KEY-123 fast path.
        if let iid = Self.iid(text) {
            // GitLab answers 404 for a number no merge request has, as it does for a project the
            // token cannot see. Here the number is by far the likelier, and it reads as nothing found.
            do { return [try await get(MergeRequestPayload.self, path: base + "/\(iid)", notFound: .projectNotFound(project)).mergeRequest] }
            catch GitLabError.projectNotFound { return [] }
        }

        var query = [URLQueryItem(name: "state", value: "opened"),
                     URLQueryItem(name: "order_by", value: "updated_at"),
                     URLQueryItem(name: "per_page", value: "25")]
        if !text.isEmpty {
            query.append(URLQueryItem(name: "search", value: text))
            query.append(URLQueryItem(name: "in", value: "title,description"))
        }
        return try await get([Lenient<MergeRequestPayload>].self, path: base, query: query, notFound: .projectNotFound(project))
            .compactMap { $0.value?.mergeRequest }
    }

    static func iid(_ text: String) -> Int? {
        guard text.range(of: #"^!?\d+$"#, options: .regularExpression) != nil else { return nil }
        return Int(text.hasPrefix("!") ? String(text.dropFirst()) : text)
    }

    /// `notFound` is what a 404 means for this `path`.
    private func get<Payload: Decodable>(_ type: Payload.Type, path: String, query: [URLQueryItem] = [],
                                         notFound: GitLabError) async throws -> Payload {
        guard let url = Self.apiURL(host: config.hostURL, path: path, query: query) else { throw GitLabError.decoding }
        var req = URLRequest(url: url)
        req.setValue(config.token, forHTTPHeaderField: "PRIVATE-TOKEN")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let data: Data
        do { (data, _) = try await HTTPJSON.send(req, session: session) }
        catch HTTPJSON.Failure.transport(let error) { throw GitLabError.network(error.localizedDescription) }
        catch HTTPJSON.Failure.status(let status) {
            switch status {
            case 401, 403: throw GitLabError.unauthorized
            case 404: throw notFound
            default: throw GitLabError.badResponse(status)
            }
        }
        guard let payload = try? Self.decoder.decode(Payload.self, from: data) else { throw GitLabError.decoding }
        return payload
    }
}

/// The fields of a merge request the picker shows.
private struct MergeRequestPayload: Decodable {
    struct Author: Decodable { var name: String? }
    var iid: Int, title: String, sourceBranch: String, targetBranch: String, webUrl: String
    var author: Author?, state: String?, draft: Bool?

    var mergeRequest: MergeRequest {
        MergeRequest(iid: iid, title: title, sourceBranch: sourceBranch, targetBranch: targetBranch,
                     author: author?.name, state: state ?? "opened", draft: draft ?? false, url: webUrl)
    }
}
