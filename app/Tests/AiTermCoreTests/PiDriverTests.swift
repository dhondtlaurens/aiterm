import Foundation
import Testing
@testable import AiTermCore

@Suite struct PiDriverTests {
    private func tempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-pi-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func ownedSource(version: Int) -> String {
        "// AiTerm PI extension schema: \(version)\nexport default function aiterm() {}\n"
    }

    private var current: String { ownedSource(version: PiDriver.schemaVersion) }

    private func driver(_ home: URL, source: String? = nil) -> PiDriver { PiDriver(home: home, source: source ?? current) }

    private func url(_ home: URL) -> URL { home.appendingPathComponent(PiDriver.path) }

    @Test func piInstallerCreatesAndUpdatesOnlyOwnedFiles() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(driver(home).state == .missing)
        try driver(home).install()
        #expect(driver(home).state == .current)

        let url = url(home)
        try ownedSource(version: 0).write(to: url, atomically: true, encoding: .utf8)
        #expect(driver(home).state == .outdated)
        try driver(home).install()
        #expect(try String(contentsOf: url, encoding: .utf8) == current)
    }

    /// Schema 2 relays pi-subagents' background agents, so a schema-1 install reads as out of date
    /// and Settings offers to update it.
    @Test func aSchemaOneInstallIsOutdated() throws {
        #expect(PiDriver.state(of: ownedSource(version: 1), expected: nil) == .outdated)
    }

    /// Schema 3 forwards `session_start`'s reason and keeps the last ctx in `relay`, so a schema-2
    /// install reads as out of date and Repair (a plain reinstall) brings it to schema 3.
    @Test func aSchemaTwoInstallIsOutdatedAndRepairInstallsTheCurrentSchema() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = url(home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ownedSource(version: 2).write(to: url, atomically: true, encoding: .utf8)

        #expect(driver(home).state == .outdated)
        try driver(home).install()
        #expect(driver(home).state == .current)
        #expect(try String(contentsOf: url, encoding: .utf8) == current)
    }

    @Test func piInstallerRefusesForeignFileWithoutChangingIt() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = url(home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreign = "export default function mine() {}"
        try foreign.write(to: url, atomically: true, encoding: .utf8)

        #expect(driver(home).probe() == DriverProbe(state: .foreign,
                                                    explanation: "A different file occupies ~/.pi/agent/extensions/aiterm-status.ts."))
        #expect(throws: HarnessDriverError.foreign(path: "~/.pi/agent/extensions/aiterm-status.ts")) { try driver(home).install() }
        #expect(try String(contentsOf: url, encoding: .utf8) == foreign)
    }

    @Test func malformedOwnedMarkerCanBeRepairedButUnreadableTargetCannot() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = url(home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// AiTerm PI extension schema: broken\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(driver(home).state == .invalidOwned)
        try driver(home).install()
        #expect(driver(home).state == .current)

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(driver(home).state == .unreadable)
        #expect(throws: HarnessDriverError.refused(path: "~/.pi/agent/extensions/aiterm-status.ts", reason: "cannot be read")) {
            try driver(home).install()
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func installerRejectsASourceWithoutTheCurrentOwnershipMarker() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(throws: HarnessDriverError.invalidSource) { try driver(home, source: ownedSource(version: 0)).install() }
        #expect(driver(home).state == .missing)
    }

    @Test func currentMarkerWithCorruptedBodyIsInvalidAgainstTheBundledSource() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let url = url(home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// AiTerm PI extension schema: \(PiDriver.schemaVersion)\ntruncated\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(driver(home).state == .invalidOwned)
    }

    /// A dotfiles-managed extension stays a link; the file it names is what gets written.
    @Test func aSymlinkedExtensionIsWrittenThroughAndStaysALink() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let link = url(home), elsewhere = home.appendingPathComponent("dotfiles/aiterm-status.ts")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ownedSource(version: 2).write(to: elsewhere, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)

        try driver(home).install()

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == elsewhere.path)
        #expect(try String(contentsOf: elsewhere, encoding: .utf8) == current)
        #expect(driver(home).state == .current)
    }

    @Test func aDanglingExtensionLinkIsUnreadableNotReplaced() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let link = url(home), missing = home.appendingPathComponent("dotfiles/gone.ts")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)

        #expect(driver(home).state == .unreadable)
        #expect(throws: HarnessDriverError.self) { try driver(home).install() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == missing.path)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
