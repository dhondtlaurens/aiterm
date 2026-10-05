import AppKit
import Foundation
import AiTermCore

/// What **Check for Updates…** does: ask the release source, say "latest" or offer the newer version,
/// and on **Update** download, verify, hand over to the install helper and quit. Every side effect is
/// injected, so tests drive the whole flow through a `ScriptedPrompter`; `live(prompter:)` wires the
/// real ones. Nothing here runs unless someone chooses the menu item.
@MainActor
final class UpdateController {
    private let prompter: Prompter
    private let currentVersion: String?
    private let channel: BuildChannel
    private let bundleURL: URL
    private let updatesDirectory: URL
    private let makeSource: () throws -> any ReleaseSource
    private let checkReplaceable: () throws -> Void
    private let stage: @Sendable (URL, ReleaseVersion) throws -> URL
    private let install: (URL) throws -> Void
    private let terminate: () -> Void
    private let showProgress: (String) -> () -> Void

    /// True from the menu choice until its last alert closes; the menu item is disabled meanwhile.
    /// Once the install helper is armed it stays true: if the quit is cancelled, that helper still
    /// waits for this process, and a second Update would restage under it and race it.
    private(set) var isBusy = false

    init(prompter: Prompter, currentVersion: String?, channel: BuildChannel = .release, bundleURL: URL, updatesDirectory: URL,
         makeSource: @escaping () throws -> any ReleaseSource,
         checkReplaceable: @escaping () throws -> Void,
         stage: @escaping @Sendable (URL, ReleaseVersion) throws -> URL,
         install: @escaping (URL) throws -> Void,
         terminate: @escaping () -> Void,
         showProgress: @escaping (String) -> () -> Void) {
        self.prompter = prompter; self.currentVersion = currentVersion; self.channel = channel
        self.bundleURL = bundleURL
        self.updatesDirectory = updatesDirectory; self.makeSource = makeSource; self.checkReplaceable = checkReplaceable
        self.stage = stage
        self.install = install; self.terminate = terminate; self.showProgress = showProgress
    }

    func checkForUpdates() async {
        guard !isBusy else { return }
        isBusy = true
        var handedOff = false
        defer { if !handedOff { isBusy = false } }
        // A dev build's ad-hoc signature could never verify a release, and replacing a build/
        // bundle with a release would lose what was being tried out, so it never asks.
        if channel == .dev { return report(UpdateError.devBuild) }
        // A translocated copy is read-only, so no helper could replace it.
        if BundleLocation.isTranslocated(bundleURL.path) { return report(UpdateError.translocated) }
        guard let current = currentVersion.flatMap(ReleaseVersion.init) else { return report(UpdateError.noFeed) }
        let source: any ReleaseSource
        do { source = try makeSource() } catch { return report(error) }

        switch await UpdateCheck.run(source: source, current: current) {
        case .current(let version):
            prompter.ask(AlertPrompt(message: "You’re on the latest version (\(version))."))
        case .failed(let error):
            report(error)
        case .cancelled:
            return
        case .available(let release):
            let answer = prompter.ask(AlertPrompt(message: "AiTerm \(release.version) is available.", buttons: ["Update", "Later"], escape: 1))
            guard answer.confirmed else { return }
            handedOff = await update(to: release, from: source)
        }
    }

    /// True once the install helper is running and the app has been asked to quit.
    private func update(to release: Release, from source: any ReleaseSource) async -> Bool {
        do { try checkReplaceable() } catch { report(error); return false }
        let image = updatesDirectory.appendingPathComponent("AiTerm-\(release.version).dmg")
        let staged: URL
        do {
            let dismiss = showProgress("Downloading AiTerm \(release.version)…")
            defer { dismiss(); try? FileManager.default.removeItem(at: image) }
            try await source.download(release, to: image)
            // `hdiutil`, `ditto` and `codesign` block for seconds, which the cooperative pool must not.
            let stage = self.stage
            staged = try await BackgroundWork.run { try stage(image, release.version) }
        } catch is CancellationError {
            return false
        } catch {
            report(error)
            return false
        }
        do { try install(staged) } catch { report(error); return false }
        terminate()
        return true
    }

    /// On launch: say why the last update didn't install, if it didn't, then clear `Updates/` —
    /// the replaced app, the helper and its result are only needed until the next version runs.
    func finishPreviousUpdate() {
        if let status = UpdateInstaller.takePreviousResult(in: updatesDirectory), status != 0 {
            report(UpdateError.installAborted(status))
        }
        UpdateInstaller.removeLeftovers(in: updatesDirectory)
    }

    private func report(_ error: Error) {
        let message = (error as? UpdateError)?.message ?? error.localizedDescription
        prompter.ask(AlertPrompt(message: message))
    }
}

extension UpdateController {
    /// The real wiring: the running bundle's version, feed and signature, the feed's token (if it
    /// takes one), the updates folder in Caches, and `NSApp.terminate` — whose normal quit path saves state first.
    static func live(prompter: Prompter) -> UpdateController {
        let bundle = Bundle.main
        let bundleURL = bundle.bundleURL, identifier = bundle.bundleIdentifier ?? ""
        let feed = bundle.object(forInfoDictionaryKey: "AiTermUpdateFeed") as? String
        let updates = AiTermPaths.updatesDirectory
        return UpdateController(
            prompter: prompter,
            currentVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            channel: BuildChannel(infoDictionary: bundle.infoDictionary),
            bundleURL: bundleURL, updatesDirectory: updates,
            makeSource: { try ReleaseFeed.source(for: feed, secrets: Keychain.shared) },
            checkReplaceable: { try UpdateInstaller.checkReplaceable(bundleURL) },
            stage: { image, version in
                let requirement = try UpdateStager.designatedRequirement(of: bundleURL)
                return try UpdateStager(expectedIdentifier: identifier, requirement: requirement).stage(dmg: image, version: version, in: updates)
            },
            install: { staged in
                try UpdateInstaller.launch(staged: staged, installed: bundleURL, updates: updates,
                                           pid: ProcessInfo.processInfo.processIdentifier)
            },
            terminate: { NSApp.terminate(nil) },
            showProgress: UpdateProgressPanel.show)
    }
}
