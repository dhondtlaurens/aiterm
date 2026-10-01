import Foundation
import Testing
@testable import AiTermCore

@Suite("AiTerm paths")
struct AiTermPathsTests {
    @Test func migratesLegacySupportDirectory() throws {
        let fileManager = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: home) }

        let legacy = home.appendingPathComponent("Library/Application Support/AIterm")
        try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("saved state".utf8).write(to: legacy.appendingPathComponent("state.json"))

        let support = try AiTermPaths.migrateSupportDirectory(homeDirectory: home)

        #expect(support.path.hasSuffix("Library/Application Support/AiTerm"))
        #expect(try String(contentsOf: support.appendingPathComponent("state.json"), encoding: .utf8) == "saved state")
        let names = try fileManager.contentsOfDirectory(atPath: support.deletingLastPathComponent().path)
        #expect(names == ["AiTerm"])
        #expect(try AiTermPaths.migrateSupportDirectory(homeDirectory: home).path == support.path)
        #expect(try String(contentsOf: support.appendingPathComponent("state.json"), encoding: .utf8) == "saved state")
    }

    @Test func leavesExistingPreferredDirectoryUntouched() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support/AiTerm")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("existing state".utf8).write(to: support.appendingPathComponent("state.json"))
        #expect(try AiTermPaths.migrateSupportDirectory(homeDirectory: home).path == support.path)
        #expect(try String(contentsOf: support.appendingPathComponent("state.json"), encoding: .utf8) == "existing state")
    }

    @Test func freshInstallDoesNotCreateDataDuringMigration() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let support = try AiTermPaths.migrateSupportDirectory(homeDirectory: home)
        #expect(support == home.appendingPathComponent("Library/Application Support/AiTerm"))
        #expect(!FileManager.default.fileExists(atPath: home.path))
    }

    @Test func migrationErrorsPropagateWithoutChangingData() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library"), withIntermediateDirectories: true)
        let blocked = home.appendingPathComponent("Library/Application Support")
        try Data("untouched".utf8).write(to: blocked)
        #expect(throws: (any Error).self) { try AiTermPaths.migrateSupportDirectory(homeDirectory: home) }
        #expect(try String(contentsOf: blocked, encoding: .utf8) == "untouched")
    }

    @Test func updatesLiveInCaches() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(AiTermPaths.updatesDirectory.path == home + "/Library/Caches/com.laurensdhondt.aiterm/Updates")
    }
}
