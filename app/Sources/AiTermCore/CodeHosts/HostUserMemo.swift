import Foundation
import Synchronization

/// A token's user, shared by repository clients until Settings saves. Connection probes bypass
/// it. Each test can bind its own cache so a parallel scratch Settings save clears only its own.
enum HostUserMemo {
    enum Service: Hashable, Sendable { case gitHub, gitLab, jira }

    private struct Key: Hashable, Sendable {
        var service: Service, host: String, token: Data, account: Data?
    }

    final class Cache: Sendable {
        private struct State: Sendable {
            var values: [Key: String] = [:]
            var generations: [Service: Int] = [:]
        }
        private let state = Mutex(State())

        func read(_ service: Service, host: String, token: String, account: String?,
                  load: @Sendable () async throws -> String) async throws -> String {
            let key = Key(service: service, host: host, token: Data(token.utf8), account: account.map { Data($0.utf8) })
            let (known, generation) = state.withLock { ($0.values[key], $0.generations[service, default: 0]) }
            if let known { try Task.checkCancellation(); return known }
            let read = try await load()
            return state.withLock { state in
                // A read begun before a save must not put the old identity back after it.
                guard state.generations[service, default: 0] == generation else { return read }
                if let known = state.values[key] { return known }
                state.values[key] = read
                return read
            }
        }

        func invalidate(_ service: Service) {
            state.withLock { state in
                state.values = state.values.filter { $0.key.service != service }
                state.generations[service, default: 0] += 1
            }
        }
    }

    @TaskLocal static var current: Cache?
    private static let shared = Cache()

    static func user(_ service: Service, host: String, token: String, account: String? = nil,
                     load: @Sendable () async throws -> String) async throws -> String {
        try await (current ?? shared).read(service, host: host, token: token, account: account, load: load)
    }

    static func invalidate(_ service: Service) { (current ?? shared).invalidate(service) }
}
