import Foundation
import Testing
@testable import AiTermCore

@Suite struct GrokHarnessServiceTests {
    let shim = "/Applications/AiTerm.app/Contents/Resources/hooks/grok-statusline-shim.sh"

    func service(home: URL) -> HarnessService {
        HarnessService(home: home, daemonPort: 47821,
                       runner: HarnessCommandRunner(locate: { $0 == "grok" ? "/bin/sh" : nil },
                                                    run: { _, _, _, _ in ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false) }),
                       resources: HarnessResources(claudeShimPath: nil, piExtensionSource: nil, grokShimPath: shim,
                                                   installationAllowed: true, unavailableReason: nil))
    }

    func home(withModels: Bool) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-grok-svc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".grok"), withIntermediateDirectories: true)
        if withModels { try GrokModelCatalogTests.cache().write(to: home.appendingPathComponent(".grok/models_cache.json")) }
        return home
    }

    @Test func missingDriverIsAWarningAndInstallMakesItReady() async throws {
        let home = try home(withModels: true); defer { try? FileManager.default.removeItem(at: home) }
        let before = await service(home: home).probe(.grok)
        #expect(before.health == .warning && before.integrationState == .missing && before.models.count == 3)
        let after = try await service(home: home).install(.grok)
        #expect(after.health == .ready && after.integrationState == .current)
    }

    @Test func noModelsExplainsHowToGetThem() async throws {
        let home = try home(withModels: false); defer { try? FileManager.default.removeItem(at: home) }
        _ = try await service(home: home).install(.grok)
        let snapshot = await service(home: home).probe(.grok)
        #expect(snapshot.summary == "No Grok models — run grok once to sign in and fetch them.")
    }

    @Test func grokForeignHooksFileBlocksInstall() async throws {
        let home = try home(withModels: true); defer { try? FileManager.default.removeItem(at: home) }
        let url = GrokHooksFile.url(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"hooks":{}}"#.write(to: url, atomically: true, encoding: .utf8)
        let snapshot = await service(home: home).probe(.grok)
        #expect(snapshot.integrationState == .foreign && !snapshot.canInstall)
        #expect(snapshot.summary == "A different file occupies ~/.grok/hooks/aiterm.json.")
    }

    @Test func unreadableConfigNamesTheFile() async throws {
        let home = try home(withModels: true); defer { try? FileManager.default.removeItem(at: home) }
        _ = try await service(home: home).install(.grok)
        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: home.appendingPathComponent(".grok/config.toml"))
        let snapshot = await service(home: home).probe(.grok)
        #expect(snapshot.integrationState == .unreadable)
        #expect(snapshot.summary == "~/.grok/config.toml cannot be read as text.")
        #expect(!snapshot.canInstall)
    }

    @Test func unreadableHooksFileNamesTheFile() async throws {
        let home = try home(withModels: true); defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: GrokHooksFile.url(home: home), withIntermediateDirectories: true)
        let snapshot = await service(home: home).probe(.grok)
        #expect(snapshot.integrationState == .unreadable)
        #expect(snapshot.summary == "~/.grok/hooks/aiterm.json cannot be read.")
    }

    @Test func builtinStatusLineAddsAContextWarning() async throws {
        let home = try home(withModels: true); defer { try? FileManager.default.removeItem(at: home) }
        try "[ui.status_line]\ntype = \"builtin\"\n".write(to: home.appendingPathComponent(".grok/config.toml"), atomically: true, encoding: .utf8)
        let snapshot = try await service(home: home).install(.grok)
        #expect(snapshot.health == .warning)
        #expect(snapshot.summary == "Grok’s built-in status line is on, so AiTerm cannot read context.")
    }
}
