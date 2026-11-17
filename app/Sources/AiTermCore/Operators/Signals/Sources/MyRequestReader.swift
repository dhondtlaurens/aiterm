import Foundation

/// Only the host is I/O here. Unchanged updated timestamps reuse the last complete thread read.
public actor MyRequestReader: SignalSourceReader {
    private let account: any SignalAccountReading
    private let conditions: RequestConditions
    private var threads: [String: (updated: Date, values: [ReviewThread])] = [:]
    public init(account: any SignalAccountReading, conditions: RequestConditions) { self.account = account; self.conditions = conditions }
    public func poll(since: Date?, full: Bool) async throws -> SignalRead {
        var read = try await account.requests(event: .myRequest, since: nil)
        guard read.complete, let user = read.accountUser else { read.complete = false; read.cursor = nil; return read }
        var matches: [SignalItem] = [], live = Set<String>()
        let allowed = Set(conditions.projects.compactMap(ItemRef.repository))
        for item in read.items {
            guard case .mergeRequest(let request) = item.item, let identity = item.item.identity,
                  item.mergeRequest?.author?.caseInsensitiveCompare(user) == .orderedSame,
                  conditions.projects.isEmpty || ItemRef.repository(request.remote).map(allowed.contains) == true else { continue }
            live.insert(identity)
            let sentBack = conditions.sentBackToMe && (item.changesRequested || item.assignees.contains { $0.caseInsensitiveCompare(user) == .orderedSame })
            var needsReply = false
            if conditions.waitingOnMyReply {
                let values: [ReviewThread]
                if let updated = item.updated, let cached = threads[identity], cached.updated == updated { values = cached.values }
                else {
                    values = try await account.threads(of: request)
                    if let updated = item.updated { threads[identity] = (updated, values) }
                }
                // An unreadable author is unknown, not evidence that someone else spoke.
                needsReply = values.contains { !$0.resolved && $0.lastAuthor.map { $0.caseInsensitiveCompare(user) != .orderedSame } == true }
            }
            if sentBack || needsReply { matches.append(item) }
        }
        threads = threads.filter { live.contains($0.key) }
        read.items = matches; read.full = true
        return read
    }
}
