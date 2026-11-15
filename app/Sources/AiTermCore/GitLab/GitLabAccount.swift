import Foundation

/// The account's global listings; repository writes remain on GitLabClient.
public struct GitLabAccount: SignalAccountReading {
    private let config: GitLabConfig
    private let session: URLSession
    public init(config: GitLabConfig, session: URLSession = .shared) { self.config = config; self.session = session }
    public func requests(event: RequestConditions.Event, since: Date?) async throws -> SignalRead {
        let at = Date()
        let api = GitLabClient.api(config, session: session, notFound: .noAPI(GitLabClient.base(config.hostURL)))
        let user = try await HostUserMemo.user(.gitLab, host: GitLabClient.base(config.hostURL), token: config.token) { try await GitLabClient.testConnection(config: config, session: session) }
        let filters = event == .reviewRequested ? ["reviewer_username"] : ["author_username", "assignee_username[]"]
        var items: [SignalItem] = [], identities = Set<String>(), complete = true
        for filter in filters {
            var ended = false
            for page in 1...100 {
                var query = [URLQueryItem(name: "scope", value: "all"), URLQueryItem(name: "state", value: "opened"),
                             URLQueryItem(name: filter, value: user), URLQueryItem(name: "per_page", value: "100"),
                             URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "order_by", value: "updated_at"),
                             URLQueryItem(name: "sort", value: "desc")]
                if let since { query.append(URLQueryItem(name: "updated_after", value: ISO8601DateFormatter().string(from: since))) }
                let values = try await api.get([Lenient<AccountRequest>].self, path: "/api/v4/merge_requests", query: query)
                if values.contains(where: { $0.value == nil }) { complete = false }
                for entry in values {
                    guard let raw = entry.value, let item = raw.item(host: config.hostURL), let id = item.item.identity else { complete = false; continue }
                    if identities.insert(id).inserted { items.append(item) }
                }
                if values.count < 100 { ended = true; break }
            }
            if !ended { complete = false }
        }
        return SignalRead(items: items, complete: complete, cursor: at, accountUser: user)
    }
    public func threads(of request: SignalRequestRef) async throws -> [ReviewThread] {
        guard let remote = RemoteURL(request.remote), remote.host == config.hostURL.host?.lowercased() else { throw GitLabError.decoding }
        return try await GitLabClient(config: config, project: remote.path, session: session).threads(of: request.number)
    }
}

private struct AccountRequest: Decodable {
    struct User: Decodable { var username: String? }
    var iid: Int, title: String, sourceBranch: String, targetBranch: String, webUrl: String
    var author: User?, assignees: [User]?, reviewers: [User]?, description: String?, updatedAt: String?, draft: Bool?
    var state: String?, detailedMergeStatus: String?
    var sourceProjectId: Int?, targetProjectId: Int?
    func item(host: URL) -> SignalItem? {
        guard let url = URL(string: webUrl), url.host?.lowercased() == host.host?.lowercased(),
              let separator = url.path.range(of: "/-/merge_requests/") else { return nil }
        let project = String(url.path[..<separator.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/" + project; components?.query = nil; components?.fragment = nil
        guard let remote = components?.url?.absoluteString, iid > 0 else { return nil }
        let request = MergeRequest(iid: iid, title: title, sourceBranch: sourceBranch, targetBranch: targetBranch,
                                   author: author?.username, state: state ?? "opened", draft: draft ?? false, url: webUrl,
                                   forkHead: sourceProjectId != nil && sourceProjectId != targetProjectId ? "project \(sourceProjectId!):\(sourceBranch)" : nil,
                                   description: description)
        return SignalItem(item: .request(remote: remote, number: iid), title: title, description: description, mergeRequest: request,
                          updated: updatedAt.flatMap(GitLabClient.date), assignees: assignees?.compactMap(\.username) ?? [],
                          changesRequested: detailedMergeStatus == "requested_changes")
    }
}
