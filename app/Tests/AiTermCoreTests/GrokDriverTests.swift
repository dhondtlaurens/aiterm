import Foundation
import Testing
@testable import AiTermCore

@Suite struct GrokDriverTests {
    let port = 47821
    let shim = "/Applications/AiTerm.app/Contents/Resources/hooks/grok-statusline-shim.sh"

    func tempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-grok-drv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    func driver(_ home: URL) -> GrokDriver { GrokDriver(home: home, daemonPort: port, shimPath: shim) }

    @Test func installMakesItCurrent() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        #expect(driver(home).state == .missing)
        try driver(home).install()
        let probe = driver(home).probe()
        #expect(probe.state == .current && probe.explanation == nil)
        #expect(probe.checks.isEmpty)
    }

    @Test func hooksWithoutTheStatusLineAreOutdated() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let url = GrokHooksFile.url(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try GrokHooksFile.contents(daemonPort: port).write(to: url)
        #expect(driver(home).state == .outdated)
    }

    @Test func aBuiltinStatusLineIsCurrentWithAContextWarning() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[ui.status_line]\ntype = \"builtin\"\n".write(to: config, atomically: true, encoding: .utf8)
        try driver(home).install()
        #expect(try String(contentsOf: config, encoding: .utf8) == "[ui.status_line]\ntype = \"builtin\"\n")
        let probe = driver(home).probe()
        #expect(probe.state == .current)
        let check = try #require(probe.checks.first)
        #expect(check.id == .context && !check.passed)
        #expect(!check.repairable, "Install writes nothing here, so Repair must not be offered for it")
        #expect(check.explanation == "Grok’s built-in status line is on, so AiTerm cannot read context.")
    }

    @Test func unreadableConfigLeavesHooksFileUnwritten() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: config)
        #expect(throws: HarnessDriverError.refused(path: "~/.grok/config.toml", reason: "cannot be read as text")) {
            try driver(home).install()
        }
        #expect(!FileManager.default.fileExists(atPath: GrokHooksFile.url(home: home).path))
    }

    /// Install would only refuse, so a config it cannot read is the driver's state even while
    /// the hooks file still needs writing.
    @Test func anUnreadableConfigIsNotOfferedEvenWithTheHooksMissing() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00, 0x41]).write(to: config)
        #expect(driver(home).probe() == DriverProbe(state: .unreadable, explanation: "~/.grok/config.toml cannot be read as text."))
    }

    @Test func aForeignHooksFileIsForeign() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let url = GrokHooksFile.url(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"hooks":{}}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(driver(home).probe() == DriverProbe(state: .foreign, explanation: "A different file occupies ~/.grok/hooks/aiterm.json."))
        #expect(throws: HarnessDriverError.foreign(path: "~/.grok/hooks/aiterm.json")) { try driver(home).install() }
    }

    /// A link to nothing is not a missing config: an atomic write to it would replace the link
    /// with a regular file, cutting the config off from wherever the link was meant to lead.
    @Test func aDanglingConfigLinkIsUnreadableNotReplaced() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let link = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let missing = home.appendingPathComponent("dotfiles/grok.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)

        let reason = "links to \(missing.path), which does not exist"
        #expect(driver(home).probe() == DriverProbe(state: .unreadable, explanation: "~/.grok/config.toml \(reason)."))
        #expect(throws: HarnessDriverError.refused(path: "~/.grok/config.toml", reason: reason)) { try driver(home).install() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == missing.path)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(!FileManager.default.fileExists(atPath: GrokHooksFile.url(home: home).path))
    }

    @Test func installSavesTheOriginalAndBacksUp() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[ui.status_line]\ntype = \"command\"\ncommand = \"~/line.sh\"\n".write(to: config, atomically: true, encoding: .utf8)
        try driver(home).install()
        let original = GrokStatusLineConfig.originalURL(home: home)
        #expect(try String(contentsOf: original, encoding: .utf8) == "~/line.sh")
        #expect(FileManager.default.fileExists(atPath: config.path + ".aiterm-backup"))
        #expect(driver(home).state == .current)
    }

    @Test func repairDoesNotReviveARemovedStatusLine() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[ui.status_line]\ntype = \"command\"\ncommand = \"~/line.sh\"\n".write(to: config, atomically: true, encoding: .utf8)
        try driver(home).install()
        let original = GrokStatusLineConfig.originalURL(home: home)
        #expect(try String(contentsOf: original, encoding: .utf8) == "~/line.sh")

        // The user turns the status line off (or deletes the table); repairing must not bring
        // the stale saved command back to life.
        try "[ui.status_line]\ntype = \"disabled\"\n".write(to: config, atomically: true, encoding: .utf8)
        try driver(home).install()
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test func repairOverAMovedBundleKeepsTheSavedOriginal() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "[ui.status_line]\ntype = \"command\"\ncommand = \"~/line.sh\"\n".write(to: config, atomically: true, encoding: .utf8)
        try driver(home).install()
        let original = GrokStatusLineConfig.originalURL(home: home)
        #expect(try String(contentsOf: original, encoding: .utf8) == "~/line.sh")

        // The bundle moved: config still names the old shim path, so the state is `.outdated`,
        // not `.missing` — the saved original must survive a repair of that.
        let movedShim = "/Users/me/Downloads/AiTerm.app/Contents/Resources/hooks/grok-statusline-shim.sh"
        try "[ui.status_line]\ntype = \"command\"\ncommand = \"\(movedShim)\"\n".write(to: config, atomically: true, encoding: .utf8)
        #expect(driver(home).state == .outdated)
        try driver(home).install()
        #expect(try String(contentsOf: original, encoding: .utf8) == "~/line.sh")
        #expect(driver(home).state == .current)
    }

    @Test func nonUTF8ConfigIsUnreadableAndNeverWritten() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data([0xFF, 0xFE, 0x00, 0x41])
        try bytes.write(to: config)
        #expect(driver(home).state == .unreadable)
        #expect(throws: HarnessDriverError.self) { try driver(home).install() }
        #expect(try Data(contentsOf: config) == bytes)
    }
}
