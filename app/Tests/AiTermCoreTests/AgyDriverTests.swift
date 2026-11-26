import AiTermTestSupport
import Foundation
import Testing
@testable import AiTermCore

/// The `aiterm` named hook in Antigravity's `~/.gemini/config/hooks.json`.
@Suite struct AgyDriverTests {
    private let port = 47821
    private let shim = "/Applications/AiTerm.app/Contents/Resources/hooks/agy-statusline-shim.sh"

    private func driver(_ home: URL, port: Int? = nil) -> AgyDriver {
        AgyDriver(home: home, daemonPort: port ?? self.port, shimPath: shim)
    }
    private func url(_ home: URL) -> URL { home.appendingPathComponent(AgyHooks.path) }
    private func settingsURL(_ home: URL) -> URL { home.appendingPathComponent(AgyStatusLine.path) }
    private func object(_ home: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url(home))) as? [String: Any])
    }
    private func settings(_ home: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL(home))) as? [String: Any])
    }
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func installWritesTheNamedHookAndReadsCurrent() throws {
        let home = try ScratchFolder.make("aiterm-agy-home-")
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(driver(home).state == .missing)
        try driver(home).install()
        #expect(driver(home).state == .current)
        let aiterm = try #require(try object(home)["aiterm"] as? [String: Any])
        #expect(Set(aiterm.keys) == ["SessionStart", "PreInvocation", "Stop"])
        // Never a PreToolUse: an answer there is a permission decision, and `{}` denies the tool.
        #expect(aiterm["PreToolUse"] == nil)
        let handler = try #require((aiterm["Stop"] as? [[String: Any]])?.first)
        #expect(handler["type"] as? String == "command")
        let command = try #require(handler["command"] as? String)
        #expect(command.contains("http://127.0.0.1:47821/hook/agy"))
        #expect(command.contains(#"X-AiTerm-iTerm-Session: $ITERM_SESSION_ID"#))
        #expect(command.hasSuffix("; echo '{}'"))
    }

    /// The person's own named hooks, a plugin's, and keys AiTerm does not know stay as they are.
    @Test func theOtherNamedHooksStayAndTheFileIsBackedUpOnce() throws {
        let home = try ScratchFolder.make("aiterm-agy-home-")
        defer { try? FileManager.default.removeItem(at: home) }
        let theirs = #"{"lint-checker":{"PostToolUse":[{"matcher":"run_command","hooks":[{"command":"./lint.sh"}]}]},"safety":{"enabled":false}}"#
        try write(theirs, to: url(home))

        try driver(home).install()
        let merged = try object(home)
        #expect(Set(merged.keys) == ["lint-checker", "safety", "aiterm"])
        #expect((merged["safety"] as? [String: Any])?["enabled"] as? Bool == false)
        let backup = url(home).appendingPathExtension("aiterm-backup")
        #expect(try String(contentsOf: backup, encoding: .utf8) == theirs)

        // A Repair that changes nothing leaves the file's bytes alone.
        let before = try Data(contentsOf: url(home))
        try driver(home).install()
        #expect(try Data(contentsOf: url(home)) == before)
    }

    /// Written for a daemon on another port, the hook posts to nothing: out of date, and Repair mends it.
    @Test func anotherPortsHookIsOutdatedUntilRepaired() throws {
        let home = try ScratchFolder.make("aiterm-agy-home-")
        defer { try? FileManager.default.removeItem(at: home) }
        try driver(home, port: 50000).install()
        #expect(driver(home).state == .outdated)
        try driver(home).install()
        #expect(driver(home).state == .current)
    }

    @Test func aFileThatIsNotAnObjectIsRefusedAndLeftAlone() throws {
        let home = try ScratchFolder.make("aiterm-agy-home-")
        defer { try? FileManager.default.removeItem(at: home) }
        try write("[1, 2]", to: url(home))

        #expect(driver(home).probe() == DriverProbe(state: .unreadable, explanation: "~/.gemini/config/hooks.json is not a JSON object."))
        #expect(throws: HarnessDriverError.refused(path: "~/.gemini/config/hooks.json", reason: "is not a JSON object")) {
            try driver(home).install()
        }
        #expect(try String(contentsOf: url(home), encoding: .utf8) == "[1, 2]")
    }

    /// With no status line of the person's, the shim takes the line and Antigravity's own stays drawn
    /// above it; the settings keep their other keys and their private permissions.
    @Test func theStatusLineRunsTheShimBesideAntigravitysOwn() throws {
        let home = try ScratchFolder.make("aiterm-agy-home-")
        defer { try? FileManager.default.removeItem(at: home) }
        try write(#"{"model":"Gemini 4 Neon (High)","trustedWorkspaces":["/repo"]}"#, to: settingsURL(home))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL(home).path)

        try driver(home).install()
        let merged = try settings(home)
        #expect(merged["model"] as? String == "Gemini 4 Neon (High)")
        let line = try #require(merged["statusLine"] as? [String: Any])
        #expect(line["type"] as? String == "command" && line["command"] as? String == shim)
        #expect(line["stack_with_default"] as? Bool == true)
        #expect(try FileManager.default.attributesOfItem(atPath: settingsURL(home).path)[.posixPermissions] as? Int == 0o600)
        #expect(ShimPort.isRecorded(port, home: home))
        #expect(!FileManager.default.fileExists(atPath: AiTermPaths.statusLineOriginalURL(home: home, agent: .agy).path))
    }

    /// The person's own status line is set aside for the shim to run, its padding kept.
    @Test func thePersonsOwnStatusLineIsKeptForTheShimToRun() throws {
        let home = try ScratchFolder.make("aiterm-agy-home-")
        defer { try? FileManager.default.removeItem(at: home) }
        try write(#"{"statusLine":{"type":"command","command":"~/bin/mine.sh","padding":2}}"#, to: settingsURL(home))

        try driver(home).install()
        let line = try #require(try settings(home)["statusLine"] as? [String: Any])
        #expect(line["command"] as? String == shim && line["padding"] as? Int == 2 && line["stack_with_default"] == nil)
        #expect(try String(contentsOf: AiTermPaths.statusLineOriginalURL(home: home, agent: .agy), encoding: .utf8) == "~/bin/mine.sh")
        // A Repair over our own shim keeps the record.
        try driver(home).install()
        #expect(try String(contentsOf: AiTermPaths.statusLineOriginalURL(home: home, agent: .agy), encoding: .utf8) == "~/bin/mine.sh")
    }

    /// Claude's and Antigravity's saved status lines are separate records: neither install touches the other's.
    @Test func claudesSavedStatusLineSurvivesAntigravitysInstallAndBack() throws {
        let home = try ScratchFolder.make("aiterm-agy-home-")
        defer { try? FileManager.default.removeItem(at: home) }
        let claude = AiTermPaths.statusLineOriginalURL(home: home, agent: .claude)
        #expect(claude.lastPathComponent == "statusline-original.cmd")
        try StatusLineOriginal.record(.foreign("claude-mine"), home: home, agent: .claude)

        try driver(home).install()                         // no status line of the person's in agy
        #expect(try String(contentsOf: claude, encoding: .utf8) == "claude-mine")

        try write(#"{"statusLine":{"type":"command","command":"agy-mine"}}"#, to: settingsURL(home))
        try driver(home).install()
        #expect(try String(contentsOf: claude, encoding: .utf8) == "claude-mine")
        #expect(try String(contentsOf: AiTermPaths.statusLineOriginalURL(home: home, agent: .agy), encoding: .utf8) == "agy-mine")

        try StatusLineOriginal.record(.missing, home: home, agent: .claude)   // Claude's line removed
        #expect(try String(contentsOf: AiTermPaths.statusLineOriginalURL(home: home, agent: .agy), encoding: .utf8) == "agy-mine")
    }

    /// Hooks current but the status line the person's again: out of date, and Repair puts the shim back.
    @Test func aStatusLineThatNoLongerRunsTheShimIsOutdated() throws {
        let home = try ScratchFolder.make("aiterm-agy-home-")
        defer { try? FileManager.default.removeItem(at: home) }
        try driver(home).install()
        try write(#"{"statusLine":{"type":"command","command":"other.sh"}}"#, to: settingsURL(home))
        #expect(driver(home).state == .outdated)
        try driver(home).install()
        #expect(driver(home).state == .current)
    }
}
