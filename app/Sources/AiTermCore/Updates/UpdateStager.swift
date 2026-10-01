import Foundation

/// Turns a downloaded disk image into an app that is safe to install: copied out of the mounted
/// image into `<directory>/<version>/`, and accepted only if it is AiTerm, is the version the release named,
/// and is signed by the same certificate as the running app. That last check does the integrity
/// work, so releases carry no checksum. Any failure leaves no staging folder behind and reports
/// `.unverified` — the reason goes nowhere a user could act on it.
public struct UpdateStager: Sendable {
    public let expectedIdentifier: String
    /// The running app's designated requirement, as `codesign -d -r-` prints it.
    public let requirement: String

    public init(expectedIdentifier: String, requirement: String) {
        self.expectedIdentifier = expectedIdentifier; self.requirement = requirement
    }

    public func stage(dmg: URL, version: ReleaseVersion, in directory: URL) throws -> URL {
        let fm = FileManager.default
        let folder = directory.appendingPathComponent(version.description, isDirectory: true)
        try? fm.removeItem(at: folder)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let app = folder.appendingPathComponent("AiTerm.app")
            try Self.mounted(dmg, at: directory.appendingPathComponent(".mount-\(UUID().uuidString)", isDirectory: true)) { volume in
                try Self.run("/usr/bin/ditto", [volume.appendingPathComponent("AiTerm.app").path, app.path])
            }
            guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == expectedIdentifier,
                  (info["CFBundleShortVersionString"] as? String).flatMap(ReleaseVersion.init) == version
            else { throw UpdateError.unverified }
            try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
            try Self.run("/usr/bin/codesign", ["--verify", "-R", "=" + requirement, app.path])
            return app
        } catch {
            try? fm.removeItem(at: folder)
            throw UpdateError.unverified
        }
    }

    /// Mounts the image read-only, hidden from Finder and the Desktop, runs `body` on its volume
    /// and always detaches it again. `hdiutil attach` checks the image's own checksum first.
    private static func mounted(_ dmg: URL, at mount: URL, _ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: mount) }
        try run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", "-quiet", "-force", mount.path], timeout: 60) }
        try body(mount)
    }

    /// An ad-hoc app's requirement is its own `cdhash`, printed commented out; a certificate-signed
    /// one names the identifier and the certificate. Either way it is the text after `designated =>`.
    public static func designatedRequirement(of app: URL) throws -> String {
        let output = try ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["-d", "-r-", app.path], timeout: 30)
        guard output.status == 0,
              let line = output.stdout.split(separator: "\n").first(where: { $0.contains("designated => ") }),
              let range = line.range(of: "designated => ") else { throw UpdateError.unverified }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let output = try ProcessRunner.run(URL(fileURLWithPath: tool), arguments, timeout: 120)
        guard output.status == 0, !output.timedOut else { throw UpdateError.unverified }
    }
}
