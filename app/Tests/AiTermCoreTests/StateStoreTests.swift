import Testing
import Foundation
import Darwin
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct StateStoreTests {
    @Test func fileStampsKeepFileAndSymlinkMetadata() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("file"), link = dir.appendingPathComponent("link")
        try Data("contents".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        for url in [file, link] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let stamp = try #require(FileStamps.stamp(url.path))
            #expect(stamp.inode == (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
            #expect(stamp.size == (attributes[.size] as? NSNumber)?.uint64Value)
            let modified = try #require(attributes[.modificationDate] as? Date)
            #expect(abs(Double(stamp.modified) / 1e9 - modified.timeIntervalSince1970) < 1e-6, "nanoseconds since the epoch")
        }
        try FileManager.default.removeItem(at: file)
        #expect(FileStamps.stamp(file.path) == nil)
        #expect(FileStamps.stamp(link.path) != nil)
    }

    /// The backup is the snapshot the store validated, whatever is on disk: an edit of the workspace file that keeps
    /// its length, its inode and its modification time to the nanosecond leaves the store's stamp matching, and the
    /// save after it must keep the bytes it knows rather than whatever the file now holds.
    @Test func theBackupIsTheValidatedSnapshotEvenWhenTheFileChangedUnseen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        try store.save(.empty)
        let validated = try Data(contentsOf: store.url)
        var info = stat()
        #expect(lstat(store.url.path, &info) == 0)
        let handle = try FileHandle(forWritingTo: store.url)
        try handle.write(contentsOf: Data("X".utf8))
        try handle.close()
        var times = [info.st_atimespec, info.st_mtimespec]
        #expect(utimensat(AT_FDCWD, store.url.path, &times, 0) == 0)
        #expect(FileStamps.stamp(store.url.path) == FileStamps.Stamp(info), "nothing the store's stamp sees changed")
        var next = AppState.empty
        next.lastModelByAgent[.claude] = "sonnet"

        try store.save(next)

        #expect(try Data(contentsOf: store.backupURL) == validated, "the backup is what was validated, not the edit")
        #expect(store.hasValidBackup)
    }

    @Test func testLoadOfMissingFileGivesEmptyState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        #expect(try StateStore(url: url).load() == .empty)
    }

    @Test func testSaveThenLoadRoundTripsAndCreatesDirectory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        let store = StateStore(url: url)
        var s = AppState.empty
        s.append(project: Project.make(name: "AiTerm", path: "/tmp/AiTerm", collapsed: true))
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

    /// A save after the store's own write does not read the file back to check it: it knows what it
    /// wrote, and keeps those bytes as the backup. Proved with a primary nothing can read — the
    /// same file, its permissions changed, which leaves its contents and modification time alone.
    @Test func aSaveAfterItsOwnWriteDoesNotReadTheFileBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        try store.save(.empty)
        let original = try Data(contentsOf: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.url.path)
        #expect(throws: (any Error).self) { try Data(contentsOf: store.url) }
        var next = AppState.empty
        next.lastModelByAgent[.claude] = "sonnet"

        try store.save(next)

        #expect(try Data(contentsOf: store.backupURL) == original)
        // An atomic write keeps the replaced file's permissions.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.url.path)
        #expect(try store.load() == next)
    }

    /// The same holds for the file it loaded: what `load` read and checked is the backup.
    @Test func aSaveAfterALoadDoesNotReadTheFileBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try StateStore(url: dir.appendingPathComponent("state.json")).save(.empty)
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        let original = try Data(contentsOf: store.url)
        #expect(try store.load() == .empty)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.url.path)
        var next = AppState.empty
        next.lastModelByAgent[.claude] = "sonnet"

        try store.save(next)

        #expect(try Data(contentsOf: store.backupURL) == original)
    }

    /// A file changed by anyone else since the store last wrote it is read and checked again: a
    /// damaged one is not overwritten, and a good one becomes the backup.
    @Test func aFileChangedOutsideTheStoreIsCheckedAgain() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"))
        try store.save(.empty)
        let damaged = Data("{broken".utf8)
        try damaged.write(to: store.url)
        #expect(throws: (any Error).self) { try store.save(.empty) }
        #expect(try Data(contentsOf: store.url) == damaged)

        var edited = AppState.empty
        edited.lastModelByAgent[.codex] = "gpt"
        let outside = try store.encoded(edited)
        try outside.write(to: store.url)
        try store.save(.empty)
        #expect(try Data(contentsOf: store.backupURL) == outside)
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
        let project = Project.make(name: "Repo", path: "/tmp/repo")
        let task = TaskItem.make(project: project.id, worktreePath: "/tmp/repo/.worktrees/work", model: "sonnet", windowId: "w1")
        let terminal = TerminalItem(id: UUID(), projectId: project.id, name: "Shell",
                                    windowId: "w2", createdAt: Date(timeIntervalSince1970: 0))
        var valid = AppState.empty
        valid.items = [.project(project)]; valid.tasks = [task]; valid.terminals = [terminal]
        try store.save(valid)
        let original = try Data(contentsOf: store.url)
        var duplicateProject = valid; duplicateProject.append(project: project)
        var duplicateTask = valid; duplicateTask.tasks.append(task)
        var duplicateTerminal = valid; duplicateTerminal.terminals.append(terminal)
        var orphanTask = valid; orphanTask.tasks[0].projectId = UUID()
        var orphanTerminal = valid; orphanTerminal.terminals[0].projectId = UUID()
        for candidate in [duplicateProject, duplicateTask, duplicateTerminal, orphanTask, orphanTerminal] {
            #expect(throws: (any Error).self) { try store.save(candidate) }
            #expect(try Data(contentsOf: store.url) == original)
            try store.encoded(candidate).write(to: store.url)
            #expect(throws: (any Error).self) { try store.load() }
            try original.write(to: store.url)
        }
        try store.encoded(valid).write(to: store.url)
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
        s.append(project: Project.make(id: shared, name: "AiTerm", path: "/tmp/AiTerm"))
        s.append(divider: SidebarDivider(id: shared, name: "Work"))
        #expect(throws: (any Error).self) { try StateStore(url: url).save(s) }
    }

    /// A save stamps the store's format beside the workspace's fields, and a load reads that format
    /// only: an older file waits for the update scripts, a newer one is refused, and neither is
    /// changed by the attempt.
    @Test func aSaveIsStampedAndOnlyThatFormatLoads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"), format: ReleaseVersion(major: 3, minor: 0, patch: 0))
        try store.save(.empty)
        let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.url))
        #expect(saved["version"] == "3.0.0" && saved["items"] == [])
        #expect(try store.load() == .empty)

        for (version, failure) in [("2.0.0", StateStore.Failure.needsUpdate(ReleaseVersion(major: 2, minor: 0, patch: 0))),
                                   ("4.0.0", .newerWorkspace(ReleaseVersion(major: 4, minor: 0, patch: 0)))] {
            var other = saved; other["version"] = .string(version)
            let bytes = try JSONEncoder().encode(other)
            try bytes.write(to: store.url)
            #expect(throws: failure) { try store.load() }
            #expect(try Data(contentsOf: store.url) == bytes)
        }
    }

    /// A backup in an older format can replace the primary, for the update scripts to bring forward;
    /// one in a newer format cannot.
    @Test func anOlderBackupIsCopiedForTheUpdateAndANewerOneRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(url: dir.appendingPathComponent("state.json"), format: ReleaseVersion(major: 3, minor: 0, patch: 0))
        try store.save(.empty)
        let older = Data(#"{"version":"2.0.0","anything":"the update reads"}"#.utf8)
        try older.write(to: store.backupURL)
        #expect(store.hasValidBackup)
        try store.replaceWithBackup()
        #expect(try Data(contentsOf: store.url) == older)

        try Data(#"{"version":"4.0.0"}"#.utf8).write(to: store.backupURL)
        #expect(!store.hasValidBackup)
        #expect(throws: StateStore.Failure.newerWorkspace(ReleaseVersion(major: 4, minor: 0, patch: 0))) { try store.replaceWithBackup() }
        #expect(try Data(contentsOf: store.url) == older)
    }
}
