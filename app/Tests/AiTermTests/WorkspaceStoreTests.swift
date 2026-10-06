import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The workspace's one mutation path: a change is one write, one round of hooks and one save
/// request, and saves are coalesced and made off the main actor.
@MainActor
struct WorkspaceStoreTests {
    private func loadedStore(saveDelay: Duration) throws -> (WorkspaceStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = WorkspaceStore(file: StateStore(url: dir.appendingPathComponent("state.json")), saveDelay: saveDelay)
        try workspace.load()
        #expect(workspace.flush())
        return (workspace, dir)
    }

    private func saved(_ workspace: WorkspaceStore) -> AppState? { try? StateStore(url: workspace.file.url).load() }

    /// A burst of changes is one write, made a moment after the first of them, of the workspace as
    /// the last left it. One write: the backup is still the file from before the burst.
    @Test func aBurstOfChangesIsSavedOnceWithTheLast() async throws {
        let (workspace, dir) = try loadedStore(saveDelay: .milliseconds(50))
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try Data(contentsOf: workspace.file.url)

        for model in ["haiku", "sonnet", "opus"] { workspace.mutate { $0.lastModelByAgent[.claude] = model } }
        #expect(saved(workspace) == .empty, "not saved at once")

        try #require(await eventually(describing: "the save") { saved(workspace)?.lastModelByAgent[.claude] == "opus" })
        #expect(try Data(contentsOf: workspace.file.backupURL) == before)
        #expect(workspace.persistenceError == nil)
    }

    /// A save is not pushed back by the changes after it: a stream of them is saved as it goes,
    /// so quitting or crashing mid-stream loses at most the last `saveDelay` of it.
    @Test func aSteadyStreamOfChangesIsStillSaved() async throws {
        let (workspace, dir) = try loadedStore(saveDelay: .milliseconds(100))
        defer { try? FileManager.default.removeItem(at: dir) }
        var savedMidStream = false
        for step in 1...60 {
            workspace.mutate { $0.lastModelByAgent[.claude] = "model-\(step)" }
            try await Task.sleep(for: .milliseconds(20))
            if saved(workspace)?.lastModelByAgent[.claude] != nil { savedMidStream = true; break }
        }
        #expect(savedMidStream)
    }

    /// Each change runs every hook once, in the order they were added; one that changes nothing
    /// runs none and asks for no save.
    @Test func hooksRunOncePerChangeInOrder() throws {
        let (workspace, dir) = try loadedStore(saveDelay: .seconds(60))
        defer { try? FileManager.default.removeItem(at: dir) }
        var heard: [String] = []
        workspace.onChange { heard.append("first") }
        workspace.onChange { heard.append("second") }

        workspace.mutate { state in
            state.lastModelByAgent[.claude] = "opus"
            state.lastModelByAgent[.codex] = "gpt"
            state.sidebarFrame = CGRect(x: 0, y: 0, width: 300, height: 800)
        }
        #expect(heard == ["first", "second"])

        let modified = try FileManager.default.attributesOfItem(atPath: workspace.file.url.path)[.modificationDate] as? Date
        #expect(workspace.flush())
        let written = try FileManager.default.attributesOfItem(atPath: workspace.file.url.path)[.modificationDate] as? Date
        #expect(written != modified)
        workspace.mutate { $0.lastModelByAgent[.claude] = "opus" }
        #expect(heard == ["first", "second"])
        #expect(workspace.flush())
        #expect(try FileManager.default.attributesOfItem(atPath: workspace.file.url.path)[.modificationDate] as? Date == written,
                "nothing changed, so nothing was written")
    }

    /// Until the file has loaded nothing is saved — not even by a flush — so a workspace that failed
    /// to load is never overwritten with what was in memory.
    @Test func nothingIsSavedBeforeTheWorkspaceLoads() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = WorkspaceStore(file: StateStore(url: dir.appendingPathComponent("state.json")), saveDelay: .zero)
        workspace.mutate { $0.lastModelByAgent[.claude] = "opus" }
        #expect(!workspace.flush())
        try await Task.sleep(for: .milliseconds(50))
        #expect(!FileManager.default.fileExists(atPath: workspace.file.url.path))
    }

    /// A background save that fails says so on the main actor, a beat after the change, which
    /// locks the workspace; one that then succeeds unlocks it.
    ///
    /// It waits for the report rather than for a deadline: the report is a turn of the main actor,
    /// which the parallel runner's hosted-view tests can hold for seconds. A failure that is never
    /// reported hangs here instead, until the time limit fails it.
    @Test(.timeLimit(.minutes(1))) func aFailedBackgroundSaveIsReportedAndARetryClearsIt() async throws {
        let (workspace, dir) = try loadedStore(saveDelay: .milliseconds(10))
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: workspace.file.backupURL, withIntermediateDirectories: false)

        workspace.mutate { $0.lastModelByAgent[.claude] = "opus" }
        #expect(workspace.canChangeWorkspace, "reported once the save has run")
        while workspace.persistenceError == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!workspace.canChangeWorkspace)

        try FileManager.default.removeItem(at: workspace.file.backupURL)
        #expect(workspace.flush())
        #expect(workspace.persistenceError == nil)
        #expect(saved(workspace)?.lastModelByAgent[.claude] == "opus")
    }

    /// A flush writes what is waiting at once, and the save it was waiting for is not made again
    /// behind it: the backup is the file from before the change, not a copy of the change.
    @Test func aFlushSavesAtOnceInsteadOfTheWaitingSave() async throws {
        let (workspace, dir) = try loadedStore(saveDelay: .milliseconds(20))
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try Data(contentsOf: workspace.file.url)

        workspace.mutate { $0.lastModelByAgent[.claude] = "opus" }
        #expect(workspace.flush())
        #expect(saved(workspace)?.lastModelByAgent[.claude] == "opus")
        try await Task.sleep(for: .milliseconds(100))
        #expect(try Data(contentsOf: workspace.file.backupURL) == before)
    }

    /// A workspace with no file yet is written by the first flush, changed or not, so quitting at
    /// once still leaves a file behind.
    @Test func aNewWorkspaceIsWrittenByTheFirstFlush() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let workspace = WorkspaceStore(file: StateStore(url: dir.appendingPathComponent("state.json")))
        try workspace.load()
        #expect(!FileManager.default.fileExists(atPath: workspace.file.url.path))
        #expect(workspace.flush())
        #expect(saved(workspace) == .empty)
    }
}
