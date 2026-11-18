import Foundation

public struct GitHubAccount {
    private let config: GitHubConfig
    private let session: URLSession
    public init(config: GitHubConfig, session: URLSession = .shared) { self.config = config; self.session = session }
    /// Reads every page of one search, up to `pages`, into `items`, once per identity; false when any page or node was not read.
    private func search(_ query: String, api: HostAPI, into items: inout [SignalItem], identities: inout Set<String>,
                        pages: Int = 100) async throws -> Bool {
        var complete = true, cursor: String?, cursors = Set<String>(), rawCount = 0
        for _ in 0..<pages {
            let body = QueryBody(query: Self.query, variables: Variables(query: query, cursor: cursor))
            let answer = try await api.send(Answer.self, method: "POST", path: "/graphql", body: body)
            if let problem = answer.errors?.first { throw GitHubError.refused(problem.message ?? "GraphQL read failed") }
            guard let page = answer.data?.search else { throw GitHubError.decoding }
            rawCount += page.nodes.count
            for node in page.nodes {
                guard let raw = node.value, let item = raw.item, let id = item.item.identity else { complete = false; continue }
                if identities.insert(id).inserted { items.append(item) }
            }
            if !page.pageInfo.hasNextPage { return complete && rawCount == page.issueCount }
            guard let next = page.pageInfo.endCursor, cursors.insert(next).inserted else { return false }
            cursor = next
        }
        return false
    }
    public func threads(of request: SignalRequestRef) async throws -> [ReviewThread] {
        guard let remote = RemoteURL(request.remote), remote.host == "github.com" else { throw GitHubError.decoding }
        return try await GitHubClient(config: config, repo: remote.path, session: session).threads(of: request.number)
    }
    private func searchAPI() -> HostAPI { GitHubClient.api(config, session: session, notFound: .badResponse(404)) }
    private static let query = """
    query($query:String!,$cursor:String){search(query:$query,type:ISSUE,first:100,after:$cursor){issueCount pageInfo{hasNextPage endCursor} nodes{... on PullRequest{number title url headRefName baseRefName isDraft body updatedAt reviewDecision author{login} repository{nameWithOwner} assignees(first:100){nodes{login} pageInfo{hasNextPage}} headRepository{nameWithOwner} headRepositoryOwner{login}}}}}
    """
}

extension GitHubAccount: SignalQueryAccount {
    public func user() async throws -> String {
        try await HostUserMemo.user(.gitHub, host: GitHubClient.api, token: config.token) { try await GitHubClient.testConnection(config: config, session: session) }
    }

    /// Throws GitHub's own refusal when it cannot run `query`, reading one page of its search.
    public func check(_ query: GitHubQuery) async throws {
        var items: [SignalItem] = [], identities = Set<String>()
        _ = try await search(query.text, api: searchAPI(), into: &items, identities: &identities, pages: 1)
    }

    public func requests(matching query: GitHubQuery) async throws -> SignalRead {
        let at = Date()
        var items: [SignalItem] = [], identities = Set<String>()
        let complete = try await search(query.text, api: searchAPI(), into: &items, identities: &identities)
        return SignalRead(items: items, complete: complete, cursor: at)
    }

    /// The Done query narrowed to the request's repository and branch, asked whether its number comes back.
    public func matches(_ query: GitHubQuery, request: SignalRequestRef, branch: String) async throws -> Bool {
        guard let remote = RemoteURL(request.remote), remote.host == "github.com" else { throw GitHubError.decoding }
        var items: [SignalItem] = [], identities = Set<String>()
        let complete = try await search(query.text + " repo:\(remote.path) head:\(branch)", api: searchAPI(), into: &items, identities: &identities)
        guard items.contains(where: { $0.item.identity == ItemRef.mergeRequest(request).identity }) else {
            guard complete else { throw IncompleteRead("pull requests") }
            return false
        }
        // `threads:` tokens are AiTerm's own: they hold on this request's threads.
        if query.threads.isEmpty { return true }
        let threads = try await self.threads(of: request), me = try await user()
        return query.threads.allSatisfy { $0.holds(on: threads, user: me) }
    }
}

private struct QueryBody: Encodable { var query: String; var variables: Variables }
private struct Variables: Encodable { var query: String; var cursor: String? }
private struct Answer: Decodable {
    struct Problem: Decodable { var message: String? }
    struct Payload: Decodable { var search: Search }
    var data: Payload?, errors: [Problem]?
}
private struct Search: Decodable {
    struct Page: Decodable { var hasNextPage: Bool; var endCursor: String? }
    var issueCount: Int, pageInfo: Page, nodes: [Lenient<AccountPull>]
}
private struct AccountPull: Decodable {
    struct User: Decodable { var login: String? }
    struct Repo: Decodable { var nameWithOwner: String }
    struct Users: Decodable { var nodes: [User]; var pageInfo: Search.Page? }
    var number: Int, title: String, url: String, headRefName: String, baseRefName: String
    var isDraft: Bool?, body: String?, author: User?, repository: Repo, updatedAt: String?, reviewDecision: String?
    var assignees: Users?, headRepository: Repo?, headRepositoryOwner: User?
    var item: SignalItem? {
        guard assignees?.pageInfo?.hasNextPage != true, number > 0 else { return nil }
        let remote = "https://github.com/" + repository.nameWithOwner
        let fork = headRepository.map { $0.nameWithOwner.lowercased() != repository.nameWithOwner.lowercased() } ?? false
        let request = MergeRequest(iid: number, title: title, sourceBranch: headRefName, targetBranch: baseRefName,
                                   author: author?.login, state: "open", draft: isDraft ?? false, url: url,
                                   forkHead: fork ? (headRepositoryOwner?.login ?? "ghost") + ":" + headRefName : nil, description: body)
        return SignalItem(item: .request(remote: remote, number: number), title: title, description: body, mergeRequest: request,
                          updated: updatedAt.flatMap(HostDate.iso8601), assignees: assignees?.nodes.compactMap(\.login) ?? [],
                          changesRequested: reviewDecision == "CHANGES_REQUESTED")
    }
}
