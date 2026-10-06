import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm

/// A source with a scripted answer. `gate`, when set, holds `latest()` until the test opens it.
///
/// Unchecked because the scripted `var`s are unguarded: a test sets them before the check starts.
/// What the check records, which a test may poll while it runs, is kept behind a lock.
private final class FakeSource: ReleaseSource, @unchecked Sendable {
    var result: Result<Release, UpdateError>
    var gate: AsyncStream<Void>?
    /// Thrown by `latest()` instead of its scripted answer.
    var latestError: Error?
    private let record = Mutex<(latestCalls: Int, downloadedTo: URL?)>((0, nil))
    var latestCalls: Int { record.withLock { $0.latestCalls } }
    var downloadedTo: URL? { record.withLock { $0.downloadedTo } }
    init(_ result: Result<Release, UpdateError>) { self.result = result }
    func latest() async throws -> Release {
        record.withLock { $0.latestCalls += 1 }
        if let gate { for await _ in gate { break } }
        if let latestError { throw latestError }
        return try result.get()
    }
    func download(_ release: Release, to destination: URL) async throws {
        record.withLock { $0.downloadedTo = destination }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("dmg".utf8).write(to: destination)
    }
}

@MainActor
@Suite(.serialized) struct UpdateControllerTests {
    let updates = FileManager.default.temporaryDirectory.appendingPathComponent("updates-\(UUID().uuidString)")
    let newer = Release(version: ReleaseVersion("0.3.0")!, assetURL: URL(string: "https://git.example.net/AiTerm-0.3.0.dmg")!)

    /// What the injected side effects saw. `stage` runs off the main actor (the controller calls it
    /// through `BackgroundWork`), so its record is lock-protected, and keeps the dispatch queue it
    /// ran on.
    ///
    /// Unchecked because its stored `var`s are mutable. `_staged` and `_stageQueues`, which `stage`
    /// writes off the main actor, are only touched with `lock` held; the other four are written by
    /// `install`, `terminate` and `showProgress`, which the main-actor controller calls on the main
    /// actor, and read by the test there.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _staged: [(URL, ReleaseVersion)] = []
        private var _stageQueues: [String] = []
        var staged: [(URL, ReleaseVersion)] { lock.withLock { _staged } }
        var stageQueues: [String] { lock.withLock { _stageQueues } }
        func recordStage(_ image: URL, _ version: ReleaseVersion) {
            let queue = String(cString: __dispatch_queue_get_label(nil))
            lock.withLock { _staged.append((image, version)); _stageQueues.append(queue) }
        }
        var installed: [URL] = []
        var terminated = 0
        var progress: [String] = []
        var dismissed = 0
    }

    fileprivate func controller(_ prompter: ScriptedPrompter, source: FakeSource? = nil, sourceError: UpdateError? = nil,
                    version: String? = "0.2.0", channel: BuildChannel = .release, bundle: String = "/Applications/AiTerm.app",
                    stageError: UpdateError? = nil, replaceError: UpdateError? = nil, log: Log) -> UpdateController {
        let stagedURL = updates.appendingPathComponent("0.3.0/AiTerm.app")
        return UpdateController(
            prompter: prompter, currentVersion: version, channel: channel, bundleURL: URL(fileURLWithPath: bundle), updatesDirectory: updates,
            makeSource: { if let sourceError { throw sourceError }; return source! },
            checkReplaceable: { if let replaceError { throw replaceError } },
            stage: { image, version in
                if let stageError { throw stageError }
                log.recordStage(image, version)
                return stagedURL
            },
            install: { log.installed.append($0) },
            terminate: { log.terminated += 1 },
            showProgress: { text in log.progress.append(text); return { log.dismissed += 1 } })
    }

    /// A cancelled check is never an alert. A download is never cancelled: the progress panel has
    /// no Cancel, and nothing cancels the menu's task.
    @Test func aCancelledCheckSaysNothing() async {
        let quiet = ScriptedPrompter(answering: "OK"), log = Log()
        let checking = FakeSource(.success(newer))
        checking.latestError = CancellationError()
        await controller(quiet, source: checking, log: log).checkForUpdates()
        #expect(quiet.asked.isEmpty)
    }

    @Test func upToDate() async {
        let prompter = ScriptedPrompter(answering: "OK"), log = Log()
        let source = FakeSource(.success(Release(version: ReleaseVersion("0.2.0")!, assetURL: newer.assetURL)))
        await controller(prompter, source: source, log: log).checkForUpdates()
        #expect(prompter.asked.map(\.message) == ["You’re on the latest version (0.2.0)."])
        #expect(prompter.asked.first?.buttons == ["OK"])
        #expect(source.downloadedTo == nil)
    }

    /// ⎋ is Later, the safe choice.
    @Test func availableButLater() async {
        let prompter = ScriptedPrompter(answering: "⎋"), log = Log()
        let source = FakeSource(.success(newer))
        await controller(prompter, source: source, log: log).checkForUpdates()
        #expect(prompter.asked.map(\.message) == ["AiTerm 0.3.0 is available."])
        #expect(prompter.asked.first?.buttons == ["Update", "Later"])
        #expect(source.downloadedTo == nil)
        #expect(log.terminated == 0)
    }

    @Test func updateDownloadsStagesInstallsAndQuits() async {
        let prompter = ScriptedPrompter(answering: "Update"), log = Log()
        let source = FakeSource(.success(newer))
        await controller(prompter, source: source, log: log).checkForUpdates()
        let image = updates.appendingPathComponent("AiTerm-0.3.0.dmg")
        #expect(source.downloadedTo == image)
        #expect(log.staged.map { $0.0 } == [image])
        #expect(log.staged.map { $0.1 } == [ReleaseVersion("0.3.0")!])
        #expect(log.installed == [updates.appendingPathComponent("0.3.0/AiTerm.app")])
        #expect(log.progress == ["Downloading AiTerm 0.3.0…"])
        #expect(log.dismissed == 1)
        #expect(log.terminated == 1)
        #expect(!FileManager.default.fileExists(atPath: image.path))
        // `hdiutil`, `ditto` and `codesign` block for seconds: not on a thread Swift concurrency shares.
        #expect(log.stageQueues.count == 1 && !log.stageQueues.contains { $0.contains("cooperative") }, "\(log.stageQueues)")
        try? FileManager.default.removeItem(at: updates)
    }

    /// Review finding: if the quit is cancelled, the armed helper still waits for this process.
    /// A second Update would restage under it and start a second helper racing the first.
    @Test func afterHandingOffToTheHelperTheItemStaysInert() async {
        let prompter = ScriptedPrompter(answering: "Update"), log = Log()
        let source = FakeSource(.success(newer))
        let updater = controller(prompter, source: source, log: log)
        await updater.checkForUpdates()
        #expect(updater.isBusy)
        await updater.checkForUpdates()
        #expect(source.latestCalls == 1)
        #expect(log.installed.count == 1)
        try? FileManager.default.removeItem(at: updates)
    }

    @Test func verificationFailureChangesNothing() async {
        let prompter = ScriptedPrompter(answering: "Update", "OK"), log = Log()
        await controller(prompter, source: FakeSource(.success(newer)), stageError: .unverified, log: log).checkForUpdates()
        #expect(prompter.asked.last?.message == "The downloaded update couldn’t be verified. Nothing was changed.")
        #expect(log.installed.isEmpty)
        #expect(log.terminated == 0)
        #expect(log.dismissed == 1)
        try? FileManager.default.removeItem(at: updates)
    }

    @Test func anAppItCannotReplaceIsReportedBeforeDownloading() async {
        let prompter = ScriptedPrompter(answering: "Update", "OK"), log = Log()
        let source = FakeSource(.success(newer))
        await controller(prompter, source: source, replaceError: .cannotReplace("/Applications"), log: log).checkForUpdates()
        #expect(prompter.asked.last?.message == "AiTerm can’t replace itself in /Applications: you don’t have permission to change it.")
        #expect(source.downloadedTo == nil)
        #expect(log.progress.isEmpty)
        #expect(log.installed.isEmpty)
    }

    /// The helper runs after AiTerm has quit, so a failed swap can only be told by the version
    /// that opens next — before `Updates/`, which holds the helper's result, is cleared.
    @Test func aFailedInstallIsReportedOnTheNextLaunch() throws {
        let prompter = ScriptedPrompter(answering: "OK"), log = Log()
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        try Data("3\n".utf8).write(to: updates.appendingPathComponent("result"))
        controller(prompter, log: log).finishPreviousUpdate()
        #expect(prompter.asked.map(\.message) == ["The update wasn’t installed: the new version couldn’t be moved into place, so the old one was put back."])
        #expect(!FileManager.default.fileExists(atPath: updates.path))
    }

    /// `Updates/` holds a whole app bundle, and a delete that stops partway must not leave the
    /// result behind to report the same failure on every launch.
    @Test func aFailureIsReportedOnceEvenWhenTheCleanupFailsPartway() throws {
        let prompter = ScriptedPrompter(answering: "OK"), log = Log()
        let locked = updates.appendingPathComponent("previous/AiTerm.app")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: locked.appendingPathComponent("marker"))
        try Data("2\n".utf8).write(to: updates.appendingPathComponent("result"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: updates)
        }
        let updater = controller(prompter, log: log)
        updater.finishPreviousUpdate()
        updater.finishPreviousUpdate()
        #expect(prompter.asked.map(\.message) == ["The update wasn’t installed: the old version couldn’t be moved aside."])
        #expect(FileManager.default.fileExists(atPath: locked.path), "the cleanup really did stop partway")
    }

    @Test func aSuccessfulOrAbsentInstallSaysNothing() throws {
        let prompter = ScriptedPrompter(), log = Log()
        controller(prompter, log: log).finishPreviousUpdate()
        try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
        try Data("0\n".utf8).write(to: updates.appendingPathComponent("result"))
        controller(prompter, log: log).finishPreviousUpdate()
        #expect(prompter.asked.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: updates.path))
    }

    @Test func sourceFailureIsOneLine() async {
        let prompter = ScriptedPrompter(answering: "OK"), log = Log()
        await controller(prompter, source: FakeSource(.failure(.rejected)), log: log).checkForUpdates()
        #expect(prompter.asked.map(\.message) == ["GitLab rejected the token in Settings › Integrations."])
    }

    @Test func missingTokenIsExplained() async {
        let prompter = ScriptedPrompter(answering: "OK"), log = Log()
        await controller(prompter, sourceError: .noToken, log: log).checkForUpdates()
        #expect(prompter.asked.map(\.message) == ["Add a GitLab token in Settings › Integrations to get updates."])
    }

    @Test func translocatedAppIsToldToMove() async {
        let prompter = ScriptedPrompter(answering: "OK"), log = Log()
        let source = FakeSource(.success(newer))
        await controller(prompter, source: source, bundle: "/private/var/folders/x/AppTranslocation/A/d/AiTerm.app", log: log).checkForUpdates()
        #expect(prompter.asked.map(\.message) == ["Move AiTerm to the Applications folder to get updates."])
        #expect(source.latestCalls == 0)
    }

    @Test func devBuildNeverAsksTheFeed() async {
        let prompter = ScriptedPrompter(answering: "OK"), log = Log()
        let source = FakeSource(.success(newer))
        await controller(prompter, source: source, channel: .dev, bundle: "/Users/me/AiTerm/build/AiTerm.app", log: log).checkForUpdates()
        #expect(prompter.asked.map(\.message) == ["This is a development build, which doesn’t update. Open AiTerm from Applications to get updates."])
        #expect(source.latestCalls == 0)
        #expect(log.installed.isEmpty)
    }

    @Test func unreadableRunningVersionIsNoFeed() async {
        let prompter = ScriptedPrompter(answering: "OK"), log = Log()
        await controller(prompter, source: FakeSource(.success(newer)), version: nil, log: log).checkForUpdates()
        #expect(prompter.asked.map(\.message) == ["This build of AiTerm has no update source."])
    }

    /// Review focus 4: choosing the item again mid-check does nothing.
    @Test func secondChoiceWhileBusyIsIgnored() async {
        let prompter = ScriptedPrompter(answering: "OK"), log = Log()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let source = FakeSource(.success(Release(version: ReleaseVersion("0.2.0")!, assetURL: newer.assetURL)))
        source.gate = gate
        let updater = controller(prompter, source: source, log: log)
        let first = Task { await updater.checkForUpdates() }
        while source.latestCalls == 0 { await Task.yield() }
        #expect(updater.isBusy)
        await updater.checkForUpdates()
        #expect(source.latestCalls == 1)
        open.yield(); open.finish()
        await first.value
        #expect(!updater.isBusy)
        #expect(prompter.asked.count == 1)
    }
}
