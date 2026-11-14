import Foundation

public struct ReviewRequestedReader: SignalSourceReader {
    private let account: any SignalAccountReading
    private let projects: [String]
    public init(account: any SignalAccountReading, projects: [String] = []) { self.account = account; self.projects = projects }
    public func poll(since: Date?, full: Bool) async throws -> SignalRead {
        // Membership, unlike an MR's content, can change without its updated timestamp moving.
        var read = try await account.requests(event: .reviewRequested, since: nil)
        if !projects.isEmpty {
            let allowed = Set(projects.compactMap(ItemRef.repository))
            read.items = read.items.filter { value in
                guard case .mergeRequest(let ref) = value.item, let key = ItemRef.repository(ref.remote) else { return false }
                return allowed.contains(key)
            }
        }
        read.full = true
        return read
    }
}
