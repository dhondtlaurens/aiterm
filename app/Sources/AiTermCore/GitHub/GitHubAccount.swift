import Foundation

public struct GitHubAccount: SignalAccountReading {
    private let config: GitHubConfig
    private let session: URLSession
    public init(config: GitHubConfig, session: URLSession = .shared) { self.config = config; self.session = session }
    public func requests(event: RequestConditions.Event, since: Date?) async throws -> SignalRead {
        let at = Date()
        let api = GitHubClient.api(config, session: session, notFound: .badResponse(404))
        let user = event == .myRequest ? try await HostUserMemo.user(.gitHub, host: GitHubClient.api, token: config.token) { try await GitHubClient.testConnection(config: config, session: session) } : nil
        let queries = event == .reviewRequested ? ["user-review-requested:@me"] : ["author:@me", "assignee:@me"]
        var items: [SignalItem] = [], identities = Set<String>(), complete = true
        for filter in queries {
            var query = "is:pr is:open " + filter
            if let since { query += " updated:>=\(ISO8601DateFormatter().string(from: since))" }
            var cursor: String?, cursors = Set<String>(), ended = false, rawCount = 0
            for _ in 0..<100 {
                let body = QueryBody(query: Self.query, variables: Variables(query: query, cursor: cursor))
                let answer = try await api.send(Answer.self, method: "POST", path: "/graphql", body: body)
                if let problem = answer.errors?.first { throw GitHubError.refused(problem.message ?? "GraphQL read failed") }
                guard let page = answer.data?.search else { throw GitHubError.decoding }
                rawCount += page.nodes.count
                if page.nodes.contains(where: { $0.value == nil }) { complete = false }
                for node in page.nodes {
                    guard let raw = node.value, let item = raw.item, let id = item.item.identity else { complete = false; continue }
                    if identities.insert(id).inserted { items.append(item) }
                }
                if !page.pageInfo.hasNextPage { ended = true; if rawCount != page.issueCount { complete = false }; break }
                guard let next = page.pageInfo.endCursor, cursors.insert(next).inserted else { break }
                cursor = next
            }
            if !ended { complete = false }
        }
        return SignalRead(items: items, complete: complete, cursor: at, accountUser: user)
    }
    public func threads(of request: SignalRequestRef) async throws -> [ReviewThread] {
        guard let remote = RemoteURL(request.remote), remote.host == "github.com" else { throw GitHubError.decoding }
        return try await GitHubClient(config: config, repo: remote.path, session: session).threads(of: request.number)
    }
    private static let query = """
    query($query:String!,$cursor:String){search(query:$query,type:ISSUE,first:100,after:$cursor){issueCount pageInfo{hasNextPage endCursor} nodes{... on PullRequest{number title url headRefName baseRefName isDraft body updatedAt reviewDecision author{login} repository{nameWithOwner} assignees(first:100){nodes{login} pageInfo{hasNextPage}} headRepository{nameWithOwner} headRepositoryOwner{login}}}}}
    """
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
                          updated: updatedAt.flatMap(GitLabClient.date), assignees: assignees?.nodes.compactMap(\.login) ?? [],
                          changesRequested: reviewDecision == "CHANGES_REQUESTED")
    }
}
