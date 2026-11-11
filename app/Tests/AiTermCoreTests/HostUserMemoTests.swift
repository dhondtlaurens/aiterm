import Foundation
import Testing
@testable import AiTermCore

@Suite struct HostUserMemoTests {
    @Test func identitiesKeepTheirHostServiceTokenAndAccountSeparate() async throws {
        let cache = HostUserMemo.Cache()
        let rows: [(HostUserMemo.Service, String, String, String?, String)] = [
            (.gitHub, "one", "a", nil, "alice"), (.gitHub, "one", "b", nil, "bob"),
            (.gitLab, "one", "a", nil, "gitlab-alice"), (.gitHub, "two", "a", nil, "other-host"),
            (.jira, "one", "a", "first", "first-account"), (.jira, "one", "a", "second", "second-account"),
            (.gitHub, "one", "\u{e9}", nil, "composed"), (.gitHub, "one", "e\u{301}", nil, "decomposed"),
        ]
        for row in rows {
            #expect(try await cache.read(row.0, host: row.1, token: row.2, account: row.3) { row.4 } == row.4)
        }
        for row in rows {
            #expect(try await cache.read(row.0, host: row.1, token: row.2, account: row.3) {
                Issue.record("An unchanged identity must be retained")
                return "miss"
            } == row.4)
        }
        cache.invalidate(.gitLab)
        #expect(try await cache.read(.gitHub, host: "one", token: "a", account: nil) {
            Issue.record("Saving another service must not clear this identity")
            return "miss"
        } == "alice")
    }

    @Test func aFailedReadIsNotKept() async throws {
        let cache = HostUserMemo.Cache()
        await #expect(throws: URLError.self) {
            _ = try await cache.read(.gitHub, host: "one", token: "a", account: nil) {
                throw URLError(.networkConnectionLost)
            }
        }
        #expect(try await cache.read(.gitHub, host: "one", token: "a", account: nil) { "sam" } == "sam")
    }

    @Test func aReadStartedBeforeASaveCannotReplaceTheNewIdentity() async throws {
        let cache = HostUserMemo.Cache()
        let (started, start) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        defer { start.finish(); release.finish() }
        let old = Task {
            try await cache.read(.gitHub, host: "one", token: "a", account: nil) {
                start.yield(())
                for await _ in released { break }
                return "old"
            }
        }
        for await _ in started { break }
        cache.invalidate(.gitHub)
        #expect(try await cache.read(.gitHub, host: "one", token: "a", account: nil) { "new" } == "new")
        release.yield(())
        #expect(try await old.value == "old")
        #expect(try await cache.read(.gitHub, host: "one", token: "a", account: nil) {
            Issue.record("The old completion must not replace the value read after the save")
            return "miss"
        } == "new")
    }
}
