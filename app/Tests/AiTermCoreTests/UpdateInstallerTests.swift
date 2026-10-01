import Foundation
import Testing
@testable import AiTermCore

@Suite struct UpdateInstallerTests {
    /// Review focus 1: a home folder with a space in it.
    func workspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("installer \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A folder standing in for an app bundle, told apart by its marker file.
    func fakeApp(at url: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: url.appendingPathComponent("marker"))
    }

    func marker(_ app: URL) -> String? { try? String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8) }

    /// Records what the helper would have opened instead of launching anything, and the result the
    /// helper had written by then — the app it opens reads that result on launch.
    func recordingOpener(in dir: URL, updates: URL) throws -> (path: String, log: URL) {
        let log = dir.appendingPathComponent("opened.log")
        let script = dir.appendingPathComponent("opener.sh")
        let result = updates.appendingPathComponent("result").path
        try Data("#!/bin/sh\nprintf '%s %s\\n' \"$1\" \"$(cat \"\(result)\")\" >> \"\(log.path)\"\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, log)
    }

    func shortLived(_ seconds: String) throws -> Process {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = [seconds]
        try p.run(); return p
    }

    @Test func swapsAndRelaunchesOnceTheAppQuits() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let installed = dir.appendingPathComponent("Apps/AiTerm.app"), updates = dir.appendingPathComponent("Updates")
        let staged = updates.appendingPathComponent("0.3.0/AiTerm.app")
        try fakeApp(at: installed, marker: "old"); try fakeApp(at: staged, marker: "new")
        let opener = try recordingOpener(in: dir, updates: updates)
        let app = try shortLived("0.3")
        let helper = try UpdateInstaller.launch(staged: staged, installed: installed, updates: updates,
                                                pid: app.processIdentifier, timeout: 10, opener: opener.path)
        helper.waitUntilExit()
        #expect(helper.terminationStatus == 0)
        #expect(marker(installed) == "new")
        #expect(marker(updates.appendingPathComponent("previous/AiTerm.app")) == "old")
        #expect(try String(contentsOf: opener.log, encoding: .utf8) == installed.path + " 0\n")
        #expect(UpdateInstaller.takePreviousResult(in: updates) == 0)
    }

    @Test func restoresTheOldAppWhenTheNewOneCannotMoveIn() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let installed = dir.appendingPathComponent("Apps/AiTerm.app"), updates = dir.appendingPathComponent("Updates")
        try fakeApp(at: installed, marker: "old")
        let opener = try recordingOpener(in: dir, updates: updates)
        let app = try shortLived("0.1")
        let helper = try UpdateInstaller.launch(staged: updates.appendingPathComponent("0.3.0/AiTerm.app"), installed: installed,
                                                updates: updates, pid: app.processIdentifier, timeout: 10, opener: opener.path)
        helper.waitUntilExit()
        #expect(helper.terminationStatus == 3)
        #expect(marker(installed) == "old")
        #expect(try String(contentsOf: opener.log, encoding: .utf8) == installed.path + " 3\n")
        #expect(UpdateInstaller.takePreviousResult(in: updates) == 3)
    }

    @Test func changesNothingWhenTheAppNeverQuits() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let installed = dir.appendingPathComponent("Apps/AiTerm.app"), updates = dir.appendingPathComponent("Updates")
        let staged = updates.appendingPathComponent("0.3.0/AiTerm.app")
        try fakeApp(at: installed, marker: "old"); try fakeApp(at: staged, marker: "new")
        let opener = try recordingOpener(in: dir, updates: updates)
        let app = try shortLived("30"); defer { app.terminate() }
        let helper = try UpdateInstaller.launch(staged: staged, installed: installed, updates: updates,
                                                pid: app.processIdentifier, timeout: 1, opener: opener.path)
        helper.waitUntilExit()
        #expect(helper.terminationStatus == 1)
        #expect(marker(installed) == "old")
        #expect(marker(staged) == "new")
        #expect(!FileManager.default.fileExists(atPath: opener.log.path))
        #expect(UpdateInstaller.takePreviousResult(in: updates) == 1)
    }

    /// Review finding: children that inherit `__CFBundleIdentifier` / `XPC_*` check in as AiTerm
    /// (the daemon's extra Dock icon); the helper's `open` must not run as the app that just quit.
    @Test func helperDoesNotInheritTheAppsLaunchIdentity() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let installed = dir.appendingPathComponent("Apps/AiTerm.app"), updates = dir.appendingPathComponent("Updates")
        let staged = updates.appendingPathComponent("0.3.0/AiTerm.app")
        try fakeApp(at: installed, marker: "old"); try fakeApp(at: staged, marker: "new")
        let log = dir.appendingPathComponent("env.log")
        let opener = dir.appendingPathComponent("opener.sh")
        try Data("#!/bin/sh\nprintf '%s %s %s\\n' \"${__CFBundleIdentifier:-none}\" \"${XPC_SERVICE_NAME:-none}\" \"${HOME:-none}\" > \"\(log.path)\"\n".utf8).write(to: opener)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
        let app = try shortLived("0.1")
        let helper = try UpdateInstaller.launch(staged: staged, installed: installed, updates: updates,
                                                pid: app.processIdentifier, timeout: 10, opener: opener.path,
                                                environment: ["__CFBundleIdentifier": "com.laurensdhondt.aiterm",
                                                              "XPC_SERVICE_NAME": "application.com.laurensdhondt.aiterm",
                                                              "HOME": "/Users/test", "PATH": "/usr/bin:/bin"])
        helper.waitUntilExit()
        #expect(try String(contentsOf: log, encoding: .utf8) == "none none /Users/test\n")
    }

    /// Review finding: without write access to the bundle and its folder, the helper's first
    /// `mv` fails after AiTerm has already quit, and the user just sees the old version
    /// reopen. That is known before anything is downloaded.
    @Test func replacingNeedsWriteAccessToTheBundleAndItsFolder() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("Apps"), installed = folder.appendingPathComponent("AiTerm.app")
        try fakeApp(at: installed, marker: "old")
        try UpdateInstaller.checkReplaceable(installed)

        for locked in [folder, installed] {
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            #expect(throws: UpdateError.cannotReplace(folder.path)) { try UpdateInstaller.checkReplaceable(installed) }
        }
        #expect(UpdateError.cannotReplace("/Applications").message
                == "AiTerm can’t replace itself in /Applications: you don’t have permission to change it.")
    }

    /// The user's `.zshenv` is not the helper's business: it can print, fail or take seconds, and
    /// runs in every zsh that is not told otherwise.
    @Test func helperSkipsTheUsersZshStartupFiles() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let installed = dir.appendingPathComponent("Apps/AiTerm.app"), updates = dir.appendingPathComponent("Updates")
        let staged = updates.appendingPathComponent("0.3.0/AiTerm.app")
        try fakeApp(at: installed, marker: "old"); try fakeApp(at: staged, marker: "new")
        let zdotdir = dir.appendingPathComponent("zdotdir"), sourced = dir.appendingPathComponent("zshenv-ran")
        try FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        try Data("touch \"\(sourced.path)\"\n".utf8).write(to: zdotdir.appendingPathComponent(".zshenv"))
        let opener = try recordingOpener(in: dir, updates: updates)
        let app = try shortLived("0.1")
        let helper = try UpdateInstaller.launch(staged: staged, installed: installed, updates: updates,
                                                pid: app.processIdentifier, timeout: 10, opener: opener.path,
                                                environment: ["ZDOTDIR": zdotdir.path, "HOME": dir.path, "PATH": "/usr/bin:/bin"])
        helper.waitUntilExit()
        #expect(helper.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: sourced.path))
    }

    @Test func aMissingOrUnreadableResultIsNoResult() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(UpdateInstaller.takePreviousResult(in: dir) == nil)
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("result"))
        #expect(UpdateInstaller.takePreviousResult(in: dir) == nil)
    }

    /// Read once: the result goes the moment it is read, whatever happens to the rest of
    /// `Updates/`, so an interrupted cleanup cannot report the same failure on every launch.
    @Test func takingTheResultRemovesItAndNothingElse() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        try fakeApp(at: dir.appendingPathComponent("previous/AiTerm.app"), marker: "old")
        try Data("3\n".utf8).write(to: dir.appendingPathComponent("result"))
        #expect(UpdateInstaller.takePreviousResult(in: dir) == 3)
        #expect(UpdateInstaller.takePreviousResult(in: dir) == nil)
        #expect(marker(dir.appendingPathComponent("previous/AiTerm.app")) == "old")
    }

    @Test func leftoversAreRemoved() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let updates = dir.appendingPathComponent("Updates")
        try fakeApp(at: updates.appendingPathComponent("previous/AiTerm.app"), marker: "old")
        UpdateInstaller.removeLeftovers(in: updates)
        #expect(!FileManager.default.fileExists(atPath: updates.path))
        UpdateInstaller.removeLeftovers(in: updates) // absent is fine
    }
}
