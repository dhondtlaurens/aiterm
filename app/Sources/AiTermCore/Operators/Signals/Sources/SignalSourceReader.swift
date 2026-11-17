import Foundation

public protocol SignalSourceReader: Sendable {
    func poll(since: Date?, full: Bool) async throws -> SignalRead
}
