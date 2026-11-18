import Foundation

/// The account's global listings; repository writes remain on GitLabClient.
public struct GitLabAccount {
    private let config: GitLabConfig
    private let session: URLSession
    public init(config: GitLabConfig, session: URLSession = .shared) { self.config = config; self.session = session }
    public func threads(of request: SignalRequestRef) async throws -> [ReviewThread] {
        guard let url = URL(string: request.remote), config.serves(url), let remote = RemoteURL(request.remote) else { throw GitLabError.decoding }
        return try await GitLabClient(config: config, project: remote.path, session: session).threads(of: request.number)
    }
}

extension GitLabAccount: SignalQueryAccount {
    public func user() async throws -> String {
        try await HostUserMemo.user(.gitLab, host: GitLabClient.base(config.hostURL), token: config.token) { try await GitLabClient.testConnection(config: config, session: session) }
    }

    /// Through GraphQL, 100 at a time to at most 100 pages, once per `project:` path.
    public func requests(matching query: GitLabQuery) async throws -> SignalRead {
        let at = Date()
        let user = try await self.user()
        var items: [SignalItem] = [], identities = Set<String>(), complete = true
        for project in query.projects.isEmpty ? [nil] : query.projects.map(Optional.some) {
            var cursor: String?, cursors = Set<String>(), ended = false
            for _ in 0..<100 {
                let page = try await list(RequestNode.self, query.request(user: user, project: project, cursor: cursor), project: project)
                for node in page.nodes {
                    guard let item = node.value?.request?.item(config: config), let id = item.item.identity else { complete = false; continue }
                    if identities.insert(id).inserted { items.append(item) }
                }
                guard page.pageInfo.hasNextPage else { ended = true; break }
                guard let next = page.pageInfo.endCursor, cursors.insert(next).inserted else { break }
                cursor = next
            }
            if !ended { complete = false }
        }
        return SignalRead(items: items, complete: complete, cursor: at, accountUser: user)
    }

    /// Asks the role's list, or without a role the project's merge requests, for this one merge request.
    public func matches(_ query: GitLabQuery, request: SignalRequestRef, branch: String) async throws -> Bool {
        guard let url = URL(string: request.remote), config.serves(url), let path = RemoteURL(request.remote)?.path, !path.isEmpty else { throw GitLabError.decoding }
        guard query.projects.isEmpty || query.projects.contains(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) else { return false }
        let page = try await list(FoundNode.self, query.request(user: try await user(), project: path, iids: [request.number], nodes: "iid"), project: path)
        guard page.nodes.contains(where: { $0.value?.iid == String(request.number) }) else { return false }
        // `threads:` tokens are AiTerm's own: they hold on this request's threads.
        if query.threads.isEmpty { return true }
        let threads = try await self.threads(of: request), me = try await user()
        return query.threads.allSatisfy { $0.holds(on: threads, user: me) }
    }

    private func list<Node: Decodable>(_ node: Node.Type, _ request: GitLabQuery.Request, project: String?) async throws -> GitLabAnswer<Node>.Connection {
        let api = GitLabClient.api(config, session: session, notFound: .noAPI(GitLabClient.base(config.hostURL)))
        let answer = try await api.send(GitLabAnswer<Node>.self, method: "POST", path: "/api/graphql", body: request)
        // Errors beside data mean the data may be partial.
        if let problem = answer.errors?.first { throw GitLabError.refused(problem.message ?? "an error") }
        guard let data = answer.data else { throw GitLabError.decoding }
        if request.variables["fullPath"] != nil {
            guard let list = data.project?.list else { throw GitLabError.projectNotFound(project ?? "") }
            return list
        }
        guard let list = data.currentUser?.list else { throw GitLabError.unauthorized }
        return list
    }
}

private struct GitLabAnswer<Node: Decodable>: Decodable {
    struct Problem: Decodable { var message: String? }
    struct Page: Decodable { var hasNextPage: Bool; var endCursor: String? }
    struct Connection: Decodable { var pageInfo: Page; var nodes: [Lenient<Node>] }
    struct Holder: Decodable { var list: Connection? }
    struct Payload: Decodable { var currentUser: Holder?; var project: Holder? }
    var data: Payload?, errors: [Problem]?
}

private struct FoundNode: Decodable { var iid: String }

/// A GraphQL merge request node, read into the same item the REST listing builds.
private struct RequestNode: Decodable {
    struct Users: Decodable { var nodes: [AccountRequest.User?]? }
    var iid: String, title: String, webUrl: String, sourceBranch: String, targetBranch: String
    var description: String?, updatedAt: String?, draft: Bool?, state: String?
    var sourceProjectId: Int?, targetProjectId: Int?, detailedMergeStatus: String?
    var author: AccountRequest.User?, assignees: Users?
    var request: AccountRequest? {
        guard let number = Int(iid) else { return nil }
        return AccountRequest(iid: number, title: title, sourceBranch: sourceBranch, targetBranch: targetBranch, webUrl: webUrl,
                              author: author, assignees: assignees?.nodes?.compactMap { $0 }, description: description,
                              updatedAt: updatedAt, draft: draft, state: state, detailedMergeStatus: detailedMergeStatus?.lowercased(),
                              sourceProjectId: sourceProjectId, targetProjectId: targetProjectId)
    }
}

private struct AccountRequest: Decodable {
    struct User: Decodable { var username: String? }
    var iid: Int, title: String, sourceBranch: String, targetBranch: String, webUrl: String
    var author: User?, assignees: [User]?, reviewers: [User]?, description: String?, updatedAt: String?, draft: Bool?
    var state: String?, detailedMergeStatus: String?
    var sourceProjectId: Int?, targetProjectId: Int?
    func item(config: GitLabConfig) -> SignalItem? {
        guard let url = URL(string: webUrl), config.serves(url),
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
                          updated: updatedAt.flatMap(HostDate.iso8601), assignees: assignees?.compactMap(\.username) ?? [],
                          changesRequested: detailedMergeStatus == "requested_changes")
    }
}
