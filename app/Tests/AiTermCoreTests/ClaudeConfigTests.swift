import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

struct ClaudeConfigTests {
    @Test func resolvesUnsetEmptyAbsoluteAndTilde() {
        let home = ScratchHome.bare
        for value in [nil, ""] as [String?] {
            #expect(ClaudeConfig(value).directory(home: home) == home.appendingPathComponent(".claude"))
            #expect(ClaudeConfig(value).globalJSON(home: home) == home.appendingPathComponent(".claude.json"))
        }
        #expect(ClaudeConfig("~/Claude Profile").directory(home: home) == home.appendingPathComponent("Claude Profile"))
        #expect(ClaudeConfig("~").directory(home: home) == home)
        #expect(ClaudeConfig("/tmp/Claude Profile").directory(home: home).path == "/tmp/Claude Profile")
        #expect(ClaudeConfig("~/.claude").globalJSON(home: home) == home.appendingPathComponent(".claude/.claude.json"))
    }

    @Test func loginShellValueIsReadAlongsideExecutableLocations() throws {
        let locator = LoginShellLocator(shell: { query in
            #expect(query.contains("CLAUDE_CONFIG_DIR"))
            return "banner\nclaude\t/usr/bin/true\n--aiterm-claude-config-dir--\n~/Claude Profile\n--aiterm-python-candidates--\n/usr/bin/python3\n"
        })
        let answers = try #require(locator.current())
        #expect(answers.claudeConfigDirectory == "~/Claude Profile")
        #expect(answers.executables["claude"] == "/usr/bin/true")
        #expect(answers.pythonOutput == "/usr/bin/python3\n")
    }

    @Test func movedReadersAndDriverUseOnlyTheConfiguredFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        func write(_ path: String, _ text: String) throws {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let config = ClaudeConfig("~/profile")
        try write(".claude/settings.json", #"{"availableModels":["wrong"]}"#)
        try write("profile/settings.json", #"{"availableModels":["moved"]}"#)
        try write("profile/.claude.json", #"{"additionalModelOptionsCache":[{"value":"extra"}]}"#)
        try write("profile/cache/model-catalog/org-cc.json", #"{"catalog":{"config":{"models":[{"id":"cached"}]}}}"#)
        let catalogue = ModelCatalogue(home: home, runner: .nothingInstalled, claudeConfig: config)
        #expect(catalogue.read(.claude).models.map(\.id) == ["cached", "moved", "extra"])
        try write("profile/settings.json", #"{"availableModels":["updated-longer"]}"#)
        #expect(catalogue.read(.claude).models.map(\.id) == ["cached", "updated-longer", "extra"])
        try write("profile/skills/user/SKILL.md", "---\nname: user\ndescription: user skill\n---\nBody")
        try write("profile/commands/command.md", "A command")
        try write("project/.claude/skills/local/SKILL.md", "---\nname: local\ndescription: project skill\n---\nBody")
        try write(".claude/commands/wrong.md", "Wrong")
        try write("profile/plugins/cache/official/plugin/1.0/skills/plugin-skill/SKILL.md", "---\ndescription: Plugin skill\n---\nBody")
        let skills = SkillCatalog.discover(agent: .claude, projectPath: home.appendingPathComponent("project").path,
                                           home: home, claudeConfig: config)
        #expect(Set(skills.map(\.name)) == ["user", "command", "local", "plugin:plugin-skill"])
        let driver = ClaudeDriver(home: home, daemonPort: 47821, shimPath: "/bin/sh", claudeConfig: config)
        try driver.install()
        #expect(ClaudeSettings.statusLineIsInstalled(home: home, shimPath: "/bin/sh", claudeConfig: config))
        #expect(!ClaudeSettings.statusLineIsInstalled(home: home, shimPath: "/bin/sh"))
        #expect(try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8) == #"{"availableModels":["wrong"]}"#)
        try write("profile/settings.json", "invalid JSON")
        #expect(throws: (any Error).self) { try driver.install() }
        #expect(try String(contentsOf: home.appendingPathComponent("profile/settings.json"), encoding: .utf8) == "invalid JSON")
        #expect(driver.probe().explanation?.contains("~/profile/settings.json") == true)
    }
}

extension ClaudeConfigTests {
    @Test func theShellQueryPreservesSpacesAndLiteralShellCharacters() throws {
        let locator = LoginShellLocator(names: ["true"])
        let result = try ProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"),
                                           ["-fc", "CLAUDE_CONFIG_DIR='~/Claude $profile; folder'; " + locator.query], timeout: 5)
        #expect(result.status == 0)
        let answers = LoginShellLocator.answers(result.stdout, names: ["true"], isExecutable: { _ in true })
        #expect(answers.claudeConfigDirectory == "~/Claude $profile; folder")
    }

    @Test func externalSettingsKeepSymlinksBackupsAndRefusalPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home"), directory = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("dotfiles.json"), settings = directory.appendingPathComponent("settings.json")
        let original = Data(#"{"userSetting":true}"#.utf8)
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: target)
        let driver = ClaudeDriver(home: home, daemonPort: 47821, shimPath: "/bin/sh", claudeConfig: ClaudeConfig(directory.path))
        try driver.install()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: settings.path) == target.path)
        #expect(try Data(contentsOf: settings.appendingPathExtension("aiterm-backup")) == original)
        let merged = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any])
        #expect(merged["userSetting"] as? Bool == true)
        try Data("broken".utf8).write(to: target)
        #expect(throws: (any Error).self) { try driver.install() }
        #expect(driver.probe().explanation?.contains(settings.path) == true)
        #expect(try String(contentsOf: target, encoding: .utf8) == "broken")
        try FileManager.default.removeItem(at: target)
        #expect(throws: (any Error).self) { try driver.install() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: settings.path) == target.path)
    }
}

extension ClaudeConfigTests {
    @Test func anAgentReviewHandsOverTheNamedSkillFromTheConfiguredFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        func skill(in folder: String, saying text: String) throws {
            let url = home.appendingPathComponent(folder).appendingPathComponent("skills/review-skill/SKILL.md")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "---\nname: review-skill\n---\n\(text)\n".write(to: url, atomically: true, encoding: .utf8)
        }
        try skill(in: ".claude", saying: "Wrong folder.")
        try skill(in: "profile", saying: "Attack every assumption.")
        let found = AgentReview.skills(in: "Review it with /review-skill", agents: [.claude], projectPath: nil, home: home,
                                       claudeConfig: ClaudeConfig("~/profile"))
        #expect(found.map(\.name) == ["review-skill"])
        #expect(found.first?.text.contains("Attack every assumption.") == true)
    }
}
