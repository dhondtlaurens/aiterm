import Foundation
import AiTermCore

/// Owns exactly one socket/retry/event lifetime. Helper process supervision stays
/// separate: a running process is not evidence of a healthy app connection.
@MainActor
final class DaemonConnection {
    private let socketPath: String
    private let onClient: @MainActor (DaemonClient?) -> Void
    private let onStatus: @MainActor (ItermConnection) -> Void
    private let onEvent: @MainActor (DaemonEvent) -> Void
    /// Answers the helper's requests for an iTerm2 API cookie (`ItermCookie`); injected by tests.
    private let requestCookie: () async -> ItermCookieAnswer
    private var lifetime: Task<Void, Never>?
    private var client: DaemonClient?

    init(socketPath: String, onClient: @escaping @MainActor (DaemonClient?) -> Void,
         onStatus: @escaping @MainActor (ItermConnection) -> Void, onEvent: @escaping @MainActor (DaemonEvent) -> Void,
         requestCookie: @escaping () async -> ItermCookieAnswer = ItermCookie.request) {
        self.socketPath = socketPath
        self.onClient = onClient
        self.onStatus = onStatus
        self.onEvent = onEvent
        self.requestCookie = requestCookie
    }

    func start() {
        guard lifetime == nil else { return }
        lifetime = Task { [weak self] in await self?.run() }
    }

    func stop() {
        lifetime?.cancel()
        lifetime = nil
        client?.disconnect()
        client = nil
        onClient(nil)
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            let connection = DaemonClient(socketPath: socketPath)
            client = connection
            do {
                try await BackgroundWork.run { try connection.connect() }
                let snapshot = try await connection.snapshot()
                try Task.checkCancellation()
                onClient(connection)
                onStatus(ItermConnection.forSnapshot(snapshot))
                attempt = 0
                // A request can reach this client twice, in a snapshot and as its event; each asks
                // iTerm2 for a single-use cookie, so answer it once.
                var answered = Set<Int>()
                func answer(_ requestId: Int?) {
                    guard let requestId, answered.insert(requestId).inserted else { return }
                    let requestCookie = self.requestCookie
                    Task { _ = try? await connection.provideCookie(requestId: requestId, await requestCookie()) }
                }
                answer(snapshot.itermCookieRequest)
                var bootstrapped = false
                for await event in connection.events {
                    guard !Task.isCancelled else { break }
                    if case .snapshot(let current) = event {
                        bootstrapped = true
                        onStatus(ItermConnection.forSnapshot(current))
                        answer(current.itermCookieRequest)
                    }
                    // Earlier buffered events must not overwrite the bootstrap snapshot.
                    guard bootstrapped else { continue }
                    if case .itermCookieRequested(let requestId) = event { answer(requestId); continue }
                    if case .itermDisconnected = event { onStatus(.itermReconnecting) }
                    if case .itermAuthFailed(let reason) = event { onStatus(.refused(reason)) }
                    if case .itermConnected = event {
                        _ = try await connection.snapshot()
                        onEvent(event)
                        continue
                    }
                    onEvent(event)
                }
                if !Task.isCancelled { onStatus(.helperUnreachable) }
            } catch {
                if !Task.isCancelled {
                    // A helper we cannot fully understand — a stale protocol version, or a snapshot
                    // with a shape this app's `Decodable`s reject — is not the same as one that is
                    // merely unreachable; retrying at it forever would never fix either.
                    if let error = error as? DaemonError, error.isMismatch {
                        onStatus(.helperMismatch)
                    } else if error is DecodingError {
                        onStatus(.helperMismatch)
                    } else { onStatus(.helperUnreachable) }
                }
            }
            connection.disconnect()
            if client === connection { client = nil; onClient(nil) }
            guard !Task.isCancelled else { break }
            do { try await Task.sleep(for: .seconds(Backoff.delay(attempt: attempt))) }
            catch { break }
            attempt += 1
        }
    }
}
