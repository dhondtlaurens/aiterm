import Foundation

public protocol SignalAccountReading: Sendable {
    func requests(event: RequestConditions.Event, since: Date?) async throws -> SignalRead
    func threads(of request: SignalRequestRef) async throws -> [ReviewThread]
}
