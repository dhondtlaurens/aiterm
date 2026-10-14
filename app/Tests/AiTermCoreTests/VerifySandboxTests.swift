import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct VerifySandboxTests {
    @Test func writesInsideTheCloneAndNowhereElse() async throws {
        let dir = try GitFixture.folder("verify-")
        // Under the home folder, not the temporary directory: the profile allows the latter.
        let outside = NSHomeDirectory() + "/Library/Caches/aiterm-verify-outside-" + UUID().uuidString + ".txt"
        defer { try? FileManager.default.removeItem(atPath: outside) }
        try await VerifySandbox.run("touch inside.txt", in: dir, timeout: .seconds(20))
        #expect(FileManager.default.fileExists(atPath: dir + "/inside.txt"))
        await #expect(throws: FixRefusal.self) { try await VerifySandbox.run("touch '\(outside)'", in: dir, timeout: .seconds(20)) }
        #expect(!FileManager.default.fileExists(atPath: outside))
    }

    @Test func hasNoNetwork() async throws {
        let dir = try GitFixture.folder("verify-net-")
        await #expect(throws: FixRefusal.verifyFailed("curl -sS --max-time 5 https://example.com", status: 6)) {
            try await VerifySandbox.run("curl -sS --max-time 5 https://example.com", in: dir, timeout: .seconds(20))
        }
    }

    /// The profile is a string; a path with a quote must not break out of it.
    @Test func aQuoteInThePathIsEscaped() {
        let profile = VerifySandbox.profile(writableRoot: #"/tmp/a "b"/c"#)
        #expect(profile.contains(#"(subpath "/tmp/a \"b\"/c")"#))
    }
}
