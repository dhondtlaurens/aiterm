import Testing
import Foundation
@testable import AiTermCore

@Suite struct StateStoreTests {
    @Test func testLoadOfMissingFileGivesEmptyState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        #expect(try StateStore(url: url).load() == .empty)
    }

    @Test func testSaveThenLoadRoundTripsAndCreatesDirectory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        let store = StateStore(url: url)
        var s = AppState.empty
        s.projects = [Project(id: UUID(), name: "AiTerm", path: "/tmp/AiTerm", provider: .git, remoteUrl: nil, addedAt: Date(timeIntervalSince1970: 0), collapsed: true)]
        try store.save(s)
        #expect(try store.load() == s)
        #expect(!FileManager.default.fileExists(atPath: url.path + ".tmp"))
    }

    @Test func testCorruptFileThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("{nope".utf8).write(to: url)
        #expect(throws: (any Error).self) { try StateStore(url: url).load() }
    }

    @Test func previousBytesBecomeBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        try store.save(.empty)
        let original = try Data(contentsOf: store.url)
        var next = AppState.empty
        next.lastModelByAgent[.claude] = "sonnet"
        try store.save(next)
        #expect(try Data(contentsOf: store.backupURL) == original)
        #expect(try store.load() == next)
    }

    @Test func corruptPrimaryIsNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let damaged = Data("{broken".utf8)
        try damaged.write(to: store.url)
        #expect(throws: (any Error).self) { try store.save(.empty) }
        #expect(try Data(contentsOf: store.url) == damaged)
    }

    @Test func failedBackupWriteLeavesPrimaryUntouched() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        try store.save(.empty)
        let original = try Data(contentsOf: store.url)
        try FileManager.default.createDirectory(at: store.backupURL, withIntermediateDirectories: false)
        var changed = AppState.empty
        changed.lastModelByAgent[.claude] = "sonnet"
        #expect(throws: (any Error).self) { try store.save(changed) }
        #expect(try Data(contentsOf: store.url) == original)
    }

    @Test func restorePreservesDamagedPrimary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        try store.save(.empty)
        try store.save(.empty)
        let damaged = Data("{broken".utf8)
        try damaged.write(to: store.url)
        #expect(try store.restoreBackup() == .empty)
        let saved = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("state.json.recovered-") }
        #expect(saved.count == 1)
        #expect(try Data(contentsOf: #require(saved.first)) == damaged)
        #expect(try store.load() == .empty)
    }

    @Test func missingPrimaryWithBackupRequiresRecovery() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        try store.save(.empty)
        try store.save(.empty)
        try FileManager.default.removeItem(at: store.url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.save(.empty) }
        #expect(try store.restoreBackup() == .empty)
    }

    @Test func invalidRelationshipsAreRejectedWithoutChangingPrimary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let project = Project(id: UUID(), name: "Repo", path: "/tmp/repo", provider: .git,
                              remoteUrl: nil, addedAt: Date(timeIntervalSince1970: 0), collapsed: false)
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Work", branch: "feat/work",
                            worktreePath: "/tmp/repo/.worktrees/work", baseBranch: "main", jira: nil,
                            agent: .claude, model: "sonnet", reasoning: nil, firstPrompt: nil,
                            appendTicket: false, createdAt: Date(timeIntervalSince1970: 0),
                            windowId: "w1")
        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Shell",
                                    windowId: "w2", createdAt: Date(timeIntervalSince1970: 0))
        var valid = AppState.empty
        valid.projects = [project]; valid.tasks = [task]; valid.terminals = [terminal]
        try store.save(valid)
        let original = try Data(contentsOf: store.url)
        var duplicateProject = valid; duplicateProject.projects.append(project)
        var duplicateTask = valid; duplicateTask.tasks.append(task)
        var duplicateTerminal = valid; duplicateTerminal.terminals.append(terminal)
        var orphanTask = valid; orphanTask.tasks[0].projectId = UUID()
        var orphanTerminal = valid; orphanTerminal.terminals[0].projectId = UUID()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        for candidate in [duplicateProject, duplicateTask, duplicateTerminal, orphanTask, orphanTerminal] {
            #expect(throws: (any Error).self) { try store.save(candidate) }
            #expect(try Data(contentsOf: store.url) == original)
            try encoder.encode(candidate).write(to: store.url)
            #expect(throws: (any Error).self) { try store.load() }
            try original.write(to: store.url)
        }
        // The unchanged AppState encoding is the legacy fixture; no envelope is added.
        try encoder.encode(valid).write(to: store.url)
        #expect(try store.load() == valid)
        try Data("{broken".utf8).write(to: store.backupURL)
        let beforeRestore = try Data(contentsOf: store.url)
        #expect(throws: (any Error).self) { try store.restoreBackup() }
        #expect(try Data(contentsOf: store.url) == beforeRestore)
    }

    @Test func unreadablePrimaryIsNotFirstLaunchOrOverwrittenByRestore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        try store.save(.empty)
        try store.save(.empty)
        #expect(store.hasValidBackup)
        try FileManager.default.removeItem(at: store.url)
        // A directory at the primary path is a deterministic read failure, including under root.
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.save(.empty) }
        #expect(throws: (any Error).self) { try store.restoreBackup() }
        var directory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: store.url.path, isDirectory: &directory))
        #expect(directory.boolValue)
        #expect(store.hasValidBackup)
    }

    @Test func restoreWorksWithoutPrimaryAndRejectsCorruptBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        #expect(!store.hasValidBackup)
        try store.save(.empty)
        try store.save(.empty)
        try FileManager.default.removeItem(at: store.url)
        #expect(try store.restoreBackup() == .empty)
        #expect(try store.load() == .empty)
        try Data("{broken".utf8).write(to: store.backupURL)
        #expect(!store.hasValidBackup)
        #expect(throws: (any Error).self) { try store.restoreBackup() }
        #expect(try store.load() == .empty)
    }

    @Test func testDuplicateItemIdsAreRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        var s = AppState.empty
        let shared = UUID()
        s.append(project: Project(id: shared, name: "AiTerm", path: "/tmp/AiTerm", provider: .git, remoteUrl: nil,
                                  addedAt: Date(timeIntervalSince1970: 0), collapsed: false))
        s.append(divider: SidebarDivider(id: shared, name: "Work"))
        #expect(throws: (any Error).self) { try StateStore(url: url).save(s) }
    }

    @Test func testLegacyFileOnDiskLoadsAndSavesAsItems() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let json = """
        {"projects":[{"id":"1EB4C0DE-0000-0000-0000-000000000001","name":"one","path":"/one",
         "provider":"git","addedAt":"1970-01-01T00:00:01Z","collapsed":false}],"tasks":[],"terminals":[]}
        """
        try Data(json.utf8).write(to: url)
        let store = StateStore(url: url)
        var loaded = try store.load()
        #expect(loaded.projects.map(\.name) == ["one"])
        loaded.append(divider: SidebarDivider(id: UUID(), name: "Work"))
        try store.save(loaded)
        #expect(try store.load() == loaded)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("\"items\""))
    }
}
