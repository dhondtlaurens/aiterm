import Foundation
import Testing
@testable import AiTermCore

@Suite struct GrokHooksFileTests {
    let port = 47821
    let shim = "/Applications/AiTerm.app/Contents/Resources/hooks/grok-statusline-shim.sh"

    func tempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-grok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test func installWritesEveryEventAndIsCurrent() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        #expect(GrokHooksFile.state(home: home, daemonPort: port) == .missing)
        try GrokDriver(home: home, daemonPort: port, shimPath: shim).install()
        #expect(GrokHooksFile.state(home: home, daemonPort: port) == .current)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: GrokHooksFile.url(home: home))) as? [String: Any])
        let hooks = try #require(object["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["SessionStart", "UserPromptSubmit", "Notification", "PostToolUse", "PostToolUseFailure",
                                    "Stop", "StopFailure", "StopCancelled"])
        let notification = try #require((hooks["Notification"] as? [[String: Any]])?.first)
        // A regular expression over the notification type (10-hooks.md): a waiting permission
        // prompt, and a finished turn gone idle.
        #expect(notification["matcher"] as? String == "permission_prompt|idle_prompt")
        let handler = try #require((notification["hooks"] as? [[String: Any]])?.first)
        #expect(handler["type"] as? String == "command" && handler["timeout"] as? Int == 5)
    }

    /// Current is what the file says, not how it is formatted: a change in Foundation's
    /// pretty-printing must not read every install as out of date, or make Install rewrite it.
    @Test func theSameHooksFormattedAnotherWayAreCurrent() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let url = GrokHooksFile.url(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let compact = try JSONSerialization.data(withJSONObject: GrokHooksFile.object(daemonPort: port))
        #expect(compact != GrokHooksFile.contents(daemonPort: port))
        try compact.write(to: url)

        #expect(GrokHooksFile.state(home: home, daemonPort: port) == .current)
        #expect(GrokHooksFile.state(home: home, daemonPort: 50000) == .outdated)
        try GrokDriver(home: home, daemonPort: port, shimPath: shim).install()
        #expect(try Data(contentsOf: url) == compact)
    }

    @Test func commandSilencesOutputAndAlwaysSucceeds() {
        // Grok reads Stop's stdout as a decision and exit 2 as "keep working".
        let command = GrokHooksFile.postCommand(daemonPort: port)
        #expect(command.hasSuffix(">/dev/null 2>&1; exit 0"))
        #expect(command.contains("http://127.0.0.1:47821/hook/grok"))
        #expect(command.contains("X-AiTerm-Hook: 1"))
    }

    @Test func commandNeverNamesABracedVariable() {
        // Grok refuses to run a hook whose `${VAR}` is unset; $ITERM_SESSION_ID is unset outside iTerm2.
        #expect(!GrokHooksFile.postCommand(daemonPort: port).contains("${"))
        #expect(GrokHooksFile.postCommand(daemonPort: port).contains("$ITERM_SESSION_ID"))
    }

    @Test func anotherPortIsOutdatedAndRepairs() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        try GrokDriver(home: home, daemonPort: 50000, shimPath: shim).install()
        #expect(GrokHooksFile.state(home: home, daemonPort: port) == .outdated)
        try GrokDriver(home: home, daemonPort: port, shimPath: shim).install()
        #expect(GrokHooksFile.state(home: home, daemonPort: port) == .current)
    }

    @Test func refusesAForeignFile() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let url = GrokHooksFile.url(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreign = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        try foreign.write(to: url, atomically: true, encoding: .utf8)
        #expect(GrokHooksFile.state(home: home, daemonPort: port) == .foreign)
        #expect(throws: HarnessDriverError.foreign(path: "~/.grok/hooks/aiterm.json")) { try GrokDriver(home: home, daemonPort: port, shimPath: shim).install() }
        #expect(try String(contentsOf: url, encoding: .utf8) == foreign)
    }

    @Test func brokenOwnedFileIsInvalidOwnedAndRepairs() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let url = GrokHooksFile.url(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{ \"hooks\": X-AiTerm-Hook: 1 /hook/grok".write(to: url, atomically: true, encoding: .utf8)
        #expect(GrokHooksFile.state(home: home, daemonPort: port) == .invalidOwned)
        try GrokDriver(home: home, daemonPort: port, shimPath: shim).install()
        #expect(GrokHooksFile.state(home: home, daemonPort: port) == .current)
    }

    @Test func aDirectoryAtThePathIsUnreadable() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: GrokHooksFile.url(home: home), withIntermediateDirectories: true)
        #expect(GrokHooksFile.state(home: home, daemonPort: port) == .unreadable)
    }

    @Test func symlinkedHooksFileWritesThroughAndTheLinkSurvives() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let link = GrokHooksFile.url(home: home)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let elsewhere = home.appendingPathComponent("dotfiles/grok-hooks.json")
        try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A dotfiles-managed symlink whose target already exists — a previous, now-outdated
        // install — not a dangling link, so `install` must write through it.
        try GrokHooksFile.contents(daemonPort: 50000).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)

        try GrokDriver(home: home, daemonPort: port, shimPath: shim).install()

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == elsewhere.path)
        #expect(try Data(contentsOf: elsewhere) == GrokHooksFile.contents(daemonPort: port))
        #expect(GrokHooksFile.state(home: home, daemonPort: port) == .current)
    }

    @Test func aDanglingSymlinkIsUnreadableNotReplaced() throws {
        let home = try tempHome(); defer { try? FileManager.default.removeItem(at: home) }
        let link = GrokHooksFile.url(home: home)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        let missing = home.appendingPathComponent("nowhere/aiterm.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)

        #expect(GrokHooksFile.state(home: home, daemonPort: port) == .unreadable)
        #expect(throws: HarnessDriverError.refused(path: "~/.grok/hooks/aiterm.json", reason: "links to \(missing.path), which does not exist")) { try GrokDriver(home: home, daemonPort: port, shimPath: shim).install() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == missing.path)
    }
}
