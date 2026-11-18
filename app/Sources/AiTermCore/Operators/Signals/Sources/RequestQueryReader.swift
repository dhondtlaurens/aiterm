import Foundation

public typealias GitLabQueryReader = RequestQueryReader<GitLabQuery>
public typealias GitHubQueryReader = RequestQueryReader<GitHubQuery>

/// Lists a query's merge requests with the account's username, then keeps those its `threads:` tokens hold for. Only the host is I/O here;
/// a request's threads are read again only once its updated time moves.
public actor RequestQueryReader<Query: Sendable>: SignalSourceReader {
    private let query: Query
    private let filters: [ThreadFilter]
    private let account: any SignalQueryAccount<Query>
    private let now: @Sendable () -> Date
    private var threads: [String: (updated: Date, values: [ReviewThread])] = [:]

    init(query: Query, filters: [ThreadFilter], account: any SignalQueryAccount<Query>, now: @escaping @Sendable () -> Date) {
        self.query = query; self.filters = filters; self.account = account; self.now = now
    }

    public func poll(since: Date?, full: Bool) async throws -> SignalRead {
        let at = now()
        var read = try await account.requests(matching: query)
        read.full = true
        guard read.complete else { read.cursor = nil; return read }
        // The account's username decides which of its merge requests are review tasks.
        let user: String
        if let known = read.accountUser { user = known } else { user = try await account.user() }
        read.accountUser = user
        if !filters.isEmpty {
            var matches: [SignalItem] = [], live = Set<String>()
            for item in read.items {
                guard case .mergeRequest(let request) = item.item, let identity = item.item.identity else { continue }
                live.insert(identity)
                let values: [ReviewThread]
                if let updated = item.updated, let cached = threads[identity], cached.updated == updated { values = cached.values }
                else {
                    values = try await account.threads(of: request)
                    if let updated = item.updated { threads[identity] = (updated, values) }
                }
                if filters.allSatisfy({ $0.holds(on: values, user: user) }) { matches.append(item) }
            }
            threads = threads.filter { live.contains($0.key) }
            read.items = matches
        }
        read.cursor = at
        return read
    }
}

extension RequestQueryReader where Query == GitLabQuery {
    public init(query: GitLabQuery, account: any SignalQueryAccount<GitLabQuery>, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(query: query, filters: query.threads, account: account, now: now)
    }
}

extension RequestQueryReader where Query == GitHubQuery {
    public init(query: GitHubQuery, account: any SignalQueryAccount<GitHubQuery>, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(query: query, filters: query.threads, account: account, now: now)
    }
}
