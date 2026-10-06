import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct UpdateStagerTests {
    let version = ReleaseVersion("0.3.0")!
    let stager = UpdateStager(expectedIdentifier: "com.test.aiterm", requirement: #"identifier "com.test.aiterm""#)

    func workspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stager-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        return dir
    }

    func image(_ dir: URL, identifier: String = "com.test.aiterm", version: String = "0.3.0") throws -> URL {
        _ = try FakeAppBundle.make(in: dir.appendingPathComponent("src"), identifier: identifier, version: version)
        let dmg = dir.appendingPathComponent("AiTerm-\(version).dmg")
        try FakeAppBundle.dmg(of: dir.appendingPathComponent("src"), to: dmg)
        return dmg
    }

    /// Review focus 3: whatever happens, nothing stays mounted from this test's folder, and
    /// `Updates/` holds at most the staged version.
    func expectNothingLeft(in dir: URL, keeping kept: [String] = []) throws {
        let info = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["info"], timeout: 30)
        #expect(!info.stdout.contains(dir.path), "a volume is still mounted under \(dir.path)")
        let updates = dir.appendingPathComponent("Updates")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: updates.path)) ?? []
        #expect(left.sorted() == kept.sorted(), "Updates/ holds \(left)")
    }

    @Test func stagesAVerifiedApp() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try stager.stage(dmg: try image(dir), version: version, in: dir.appendingPathComponent("Updates"))
        #expect(staged.path == dir.appendingPathComponent("Updates/0.3.0/AiTerm.app").path)
        #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/Info.plist").path))
        try expectNothingLeft(in: dir, keeping: ["0.3.0"])
    }

    @Test func rejectsWrongIdentifier() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let dmg = try image(dir, identifier: "com.someone.else")
        #expect(throws: UpdateError.unverified) { _ = try stager.stage(dmg: dmg, version: version, in: dir.appendingPathComponent("Updates")) }
        try expectNothingLeft(in: dir)
    }

    @Test func rejectsVersionThatIsNotTheRelease() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let dmg = try image(dir, version: "0.2.9")
        #expect(throws: UpdateError.unverified) { _ = try stager.stage(dmg: dmg, version: version, in: dir.appendingPathComponent("Updates")) }
        try expectNothingLeft(in: dir)
    }

    /// The running app is certificate-signed; an ad-hoc app cannot satisfy its requirement.
    @Test func rejectsAppNotSignedByTheSameCertificate() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let strict = UpdateStager(expectedIdentifier: "com.test.aiterm",
                                  requirement: #"identifier "com.test.aiterm" and certificate leaf = H"0000000000000000000000000000000000000000""#)
        #expect(throws: UpdateError.unverified) { _ = try strict.stage(dmg: try image(dir), version: version, in: dir.appendingPathComponent("Updates")) }
        try expectNothingLeft(in: dir)
    }

    @Test func rejectsAnImageWithoutTheApp() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("hi".utf8).write(to: dir.appendingPathComponent("src/README.txt"))
        let dmg = dir.appendingPathComponent("AiTerm-0.3.0.dmg")
        try FakeAppBundle.dmg(of: dir.appendingPathComponent("src"), to: dmg)
        #expect(throws: UpdateError.unverified) { _ = try stager.stage(dmg: dmg, version: version, in: dir.appendingPathComponent("Updates")) }
        try expectNothingLeft(in: dir)
    }

    /// A lost session or a captive portal answers with a 200 HTML page.
    @Test func rejectsADownloadThatIsNotAnImage() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let dmg = dir.appendingPathComponent("AiTerm-0.3.0.dmg")
        try Data("<!DOCTYPE html><title>Sign in</title>".utf8).write(to: dmg)
        #expect(throws: UpdateError.unverified) { _ = try stager.stage(dmg: dmg, version: version, in: dir.appendingPathComponent("Updates")) }
        try expectNothingLeft(in: dir)
    }

    /// Leftovers from an earlier failed attempt at the same version are not trusted.
    @Test func startsFromACleanFolder() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let stale = dir.appendingPathComponent("Updates/0.3.0/AiTerm.app/Contents")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: stale.appendingPathComponent("leftover"))
        let staged = try stager.stage(dmg: try image(dir), version: version, in: dir.appendingPathComponent("Updates"))
        #expect(!FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/leftover").path))
    }

    @Test func readsAnAdHocRequirement() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try FakeAppBundle.make(in: dir.appendingPathComponent("src"))
        #expect(try UpdateStager.designatedRequirement(of: app).hasPrefix(#"cdhash H""#))
    }
}
