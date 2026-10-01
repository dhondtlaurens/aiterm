import Foundation
@testable import AiTermCore

/// A minimal ad-hoc-signed `AiTerm.app` — an Info.plist and a shell-script executable — so staging
/// can be tested against real `hdiutil`, `ditto` and `codesign` without building the app.
enum FakeAppBundle {
    static func make(in folder: URL, identifier: String = "com.test.aiterm", version: String = "0.3.0") throws -> URL {
        let app = folder.appendingPathComponent("AiTerm.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("AiTerm")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "AiTerm",
                                   "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try check(ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", app.path], timeout: 30))
        return app
    }

    /// A disk image whose volume holds what `folder` holds — `AiTerm.app` itself, for the usual case.
    static func dmg(of folder: URL, to dmg: URL) throws {
        try check(ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                    ["create", "-quiet", "-ov", "-fs", "HFS+", "-format", "UDZO", "-volname", "AiTerm",
                                     "-srcfolder", folder.path, dmg.path], timeout: 120))
    }

    private static func check(_ output: ProcessOutput) throws {
        guard output.status == 0 else { throw NSError(domain: "FakeAppBundle", code: Int(output.status), userInfo: [NSLocalizedDescriptionKey: output.stderr]) }
    }
}
