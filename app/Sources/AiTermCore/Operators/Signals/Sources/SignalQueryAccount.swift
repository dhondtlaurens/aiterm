import Foundation

/// A code host account read through a trigger's query.
public protocol SignalQueryAccount<Query>: Sendable {
    associatedtype Query: Sendable
    /// The account's username.
    func user() async throws -> String
    /// Every item a Start query lists; complete only when every page was read and every entry decoded.
    func requests(matching query: Query) async throws -> SignalRead
    /// Whether one request matches a Done query now; throws when that cannot be read.
    func matches(_ query: Query, request: SignalRequestRef, branch: String) async throws -> Bool
    func threads(of request: SignalRequestRef) async throws -> [ReviewThread]
}
