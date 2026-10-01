import Foundation
import Testing
@testable import AiTermCore

/// What the Settings card sees of each driver's files, through `HarnessService`: the same rules
/// for every harness — a link to nothing is unreadable (so Install is not offered), and a refusal
/// reaches the card as its own sentence, not "The operation couldn’t be completed."
@Suite struct HarnessServiceDriverTests {
    let shim = "/Applications/AiTerm.app/Contents/Resources/hooks/claude-statusline-shim.sh"

    func tempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-svc-drv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    func service(home: URL) -> HarnessService {
        HarnessService(home: home, daemonPort: 47821,
                       runner: HarnessCommandRunner(locate: { _ in "/bin/sh" },
                                                    run: { _, _, _, _ in ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false) }),
                       resources: HarnessResources(claudeShimPath: shim, piExtensionSource: nil, grokShimPath: nil,
                                                   installationAllowed: true, unavailableReason: nil))
    }

    @Test(arguments: [(AgentKind.claude, ".claude/settings.json"), (AgentKind.codex, ".codex/config.toml")])
    func aDanglingSettingsLinkIsUnreadableAndNotOffered(agent: AgentKind, path: String) async throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let link = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let missing = home.appendingPathComponent("dotfiles/gone")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)

        let snapshot = await service(home: home).probe(agent)
        #expect(snapshot.integrationState == .unreadable)
        #expect(!snapshot.canInstall)
        #expect(snapshot.summary == "~/\(path) links to \(missing.path), which does not exist.")
        await #expect(throws: HarnessServiceError.self) { _ = try await service(home: home).install(agent) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == missing.path)
    }

    /// The card shows `localizedDescription`, so a refusal must carry its own sentence.
    @Test func aRefusedMergeExplainsItself() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: home.appendingPathComponent("gone.json"))
        let error = #expect(throws: (any Error).self) {
            try ClaudeDriver(home: home, daemonPort: 47821, shimPath: shim).install()
        }
        #expect(error?.localizedDescription.hasPrefix("Refusing to") == true)
        #expect(error?.localizedDescription.contains("gone.json") == true)
    }
}
