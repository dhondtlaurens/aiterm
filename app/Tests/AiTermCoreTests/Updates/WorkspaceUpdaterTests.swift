import Testing
import Foundation
@testable import AiTermCore

@Suite struct WorkspaceUpdaterTests {
    private static func v(_ text: String) -> ReleaseVersion { ReleaseVersion(text)! }

    /// A scratch support folder with `state.json` holding `state`, or none when it is nil.
    private static func folder(holding state: JSONValue?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let state { try JSONEncoder().encode(state).write(to: dir.appendingPathComponent("state.json")) }
        return dir
    }

    private static func read(_ url: URL) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    /// A script that appends its version to the top-level `ran` list.
    private static func marking(_ version: String, failing: Bool = false) -> UpdateScript {
        UpdateScript(version: v(version), summary: "marks \(version)") { context in
            struct Refused: LocalizedError { var errorDescription: String? { "refused" } }
            if failing { throw Refused() }
            let ran = context.state["ran"]?.arrayValue ?? []
            context.state["ran"] = .array(ran + [.string(version)])
        }
    }

    private static func run(_ updater: WorkspaceUpdater, in dir: URL) throws {
        try updater.run(defaults: ScratchDefaults.make(), home: dir)
    }

    @Test func aFreshInstallHasNothingToUpdate() throws {
        let dir = try Self.folder(holding: nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        let updater = WorkspaceUpdater(url: dir.appendingPathComponent("state.json"), scripts: [Self.marking("2.0.0")], current: Self.v("2.0.0"))
        #expect(try updater.plan() == .upToDate)
        try Self.run(updater, in: dir)
        #expect(!FileManager.default.fileExists(atPath: updater.url.path))
    }

    @Test func aWorkspaceWithoutAVersionIsTheBaseline() throws {
        #expect(try WorkspaceUpdater.version(of: ["items": []]) == UpdateScripts.baseline)
        #expect(try WorkspaceUpdater.version(of: ["version": "2.0.0"]) == Self.v("2.0.0"))
        #expect(throws: WorkspaceUpdater.Failure.unreadableVersion("\"two\"")) { try WorkspaceUpdater.version(of: ["version": "two"]) }
        #expect(throws: WorkspaceUpdater.Failure.unreadableVersion("2")) { try WorkspaceUpdater.version(of: ["version": 2]) }
        #expect(throws: WorkspaceUpdater.Failure.notAWorkspace) { try WorkspaceUpdater.version(of: [1, 2]) }
    }

    /// Someone who skipped 2.x and 3.x goes through both steps on the way to 4.0.0, in order, and
    /// not through one newer than this build.
    @Test func skippedVersionsRunEveryStepInOrder() throws {
        let dir = try Self.folder(holding: ["items": []])
        defer { try? FileManager.default.removeItem(at: dir) }
        let scripts = [Self.marking("4.0.0"), Self.marking("2.0.0"), Self.marking("3.0.0"), Self.marking("5.0.0")]
        let updater = WorkspaceUpdater(url: dir.appendingPathComponent("state.json"), scripts: scripts, current: Self.v("4.0.0"))
        #expect(try updater.plan() == .update(from: Self.v("1.5.0"), steps: [Self.v("2.0.0"), Self.v("3.0.0"), Self.v("4.0.0")]))

        try Self.run(updater, in: dir)

        let state = try Self.read(updater.url)
        #expect(state["ran"] == ["2.0.0", "3.0.0", "4.0.0"])
        #expect(state["version"] == "4.0.0")
        #expect(try updater.plan() == .upToDate)
        #expect(try Self.read(updater.beforeUpdateURL(from: Self.v("1.5.0"))) == ["items": []], "the file as it was is kept")
    }

    @Test func onlyTheStepsAfterTheStoredVersionRun() throws {
        let dir = try Self.folder(holding: ["version": "2.0.0"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let updater = WorkspaceUpdater(url: dir.appendingPathComponent("state.json"),
                                       scripts: [Self.marking("2.0.0"), Self.marking("3.0.0")], current: Self.v("3.0.0"))
        try Self.run(updater, in: dir)
        #expect(try Self.read(updater.url) == ["version": "3.0.0", "ran": ["3.0.0"]])
    }

    /// A step that fails leaves the file at the last step that finished; the next launch resumes
    /// there, and the copy kept before the first step is never replaced by a later one.
    @Test func aFailedStepResumesWhereItStoppedAndKeepsTheOriginal() throws {
        let original: JSONValue = ["items": [], "original": true]
        let dir = try Self.folder(holding: original)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let failing = WorkspaceUpdater(url: url, scripts: [Self.marking("2.0.0"), Self.marking("3.0.0", failing: true)], current: Self.v("3.0.0"))

        #expect(throws: WorkspaceUpdater.Failure.scriptFailed(Self.v("3.0.0"), "refused")) { try Self.run(failing, in: dir) }
        #expect(try Self.read(url)["version"] == "2.0.0")
        #expect(try failing.plan() == .update(from: Self.v("2.0.0"), steps: [Self.v("3.0.0")]))

        let fixed = WorkspaceUpdater(url: url, scripts: [Self.marking("2.0.0"), Self.marking("3.0.0")], current: Self.v("3.0.0"))
        try Self.run(fixed, in: dir)
        #expect(try Self.read(url)["ran"] == ["2.0.0", "3.0.0"])
        #expect(try Self.read(fixed.beforeUpdateURL(from: Self.v("1.5.0"))) == original)
    }

    @Test func aNewerWorkspaceIsRefusedAndLeftAlone() throws {
        let dir = try Self.folder(holding: ["version": "3.0.0"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let updater = WorkspaceUpdater(url: dir.appendingPathComponent("state.json"), scripts: [Self.marking("2.0.0")], current: Self.v("2.0.0"))
        let before = try Data(contentsOf: updater.url)
        #expect(try updater.plan() == .newer(Self.v("3.0.0")))
        #expect(throws: WorkspaceUpdater.Failure.newerWorkspace(Self.v("3.0.0"))) { try Self.run(updater, in: dir) }
        #expect(try Data(contentsOf: updater.url) == before)
    }

    /// The scripts the app ships: oldest first, each a major's `.0.0`, each after the baseline.
    @Test func theShippedScriptsAreMajorsInOrder() {
        let versions = UpdateScripts.all.map(\.version)
        #expect(versions == versions.sorted() && Set(versions).count == versions.count)
        #expect(versions.allSatisfy { $0.minor == 0 && $0.patch == 0 && $0 > UpdateScripts.baseline })
        #expect(UpdateScripts.current == versions.last ?? UpdateScripts.baseline)
    }
}
