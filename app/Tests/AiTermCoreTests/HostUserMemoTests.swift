import Foundation
import Testing
@testable import AiTermCore

@Suite struct HostUserMemoTests {
    @Test func identitiesKeepTheirHostServiceAndTokenSeparate() async throws {
        let cache = HostUserMemo.Cache()
        let rows: [(HostUserMemo.Service, String, String, String)] = [
            (.gitHub, "one", "a", "alice"), (.gitHub, "one", "b", "bob"),
            (.gitLab, "one", "a", "gitlab-alice"), (.gitHub, "two", "a", "other-host"),
            (.gitHub, "one", "\u{e9}", "composed"), (.gitHub, "one", "e\u{301}", "decomposed"),
        ]
        for row in rows {
            #expect(try await cache.read(row.0, host: row.1, token: row.2) { row.3 } == row.3)
        }
        for row in rows {
            #expect(try await cache.read(row.0, host: row.1, token: row.2) {
                Issue.record("An unchanged identity must be retained")
                return "miss"
            } == row.3)
        }
        cache.invalidate(.gitLab)
        #expect(try await cache.read(.gitHub, host: "one", token: "a") {
            Issue.record("Saving another service must not clear this identity")
            return "miss"
        } == "alice")
    }

    @Test func aFailedReadIsNotKept() async throws {
        let cache = HostUserMemo.Cache()
        await #expect(throws: URLError.self) {
            _ = try await cache.read(.gitHub, host: "one", token: "a") {
                throw URLError(.networkConnectionLost)
            }
        }
        #expect(try await cache.read(.gitHub, host: "one", token: "a") { "sam" } == "sam")
    }

    @Test func aReadStartedBeforeASaveCannotReplaceTheNewIdentity() async throws {
        let cache = HostUserMemo.Cache()
        let (started, start) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        defer { start.finish(); release.finish() }
        let old = Task {
            try await cache.read(.gitHub, host: "one", token: "a") {
                start.yield(())
                for await _ in released { break }
                return "old"
            }
        }
        for await _ in started { break }
        cache.invalidate(.gitHub)
        #expect(try await cache.read(.gitHub, host: "one", token: "a") { "new" } == "new")
        release.yield(())
        #expect(try await old.value == "old")
        #expect(try await cache.read(.gitHub, host: "one", token: "a") {
            Issue.record("The old completion must not replace the value read after the save")
            return "miss"
        } == "new")
    }
}
