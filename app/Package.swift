// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "AiTerm",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "AiTermCore", path: "Sources/AiTermCore",
                linkerSettings: [.linkedFramework("CoreWLAN"), .linkedFramework("IOKit"), .linkedFramework("CoreLocation")]),
        .target(name: "AiTermUI", path: "Sources/AiTermUI", exclude: ["README.md"]),
        // Resources/ is not a SwiftPM resource: no code reads a resource bundle, and make-app.sh copies
        // the Info.plist and the icon from it into AiTerm.app itself.
        .executableTarget(name: "AiTerm", dependencies: ["AiTermCore", "AiTermUI"], path: "Sources/AiTerm",
                          exclude: ["Resources"]),
        // Fakes and fixtures the Core and app tests share: test targets cannot share a source file, so
        // they live in a library the tests import. It uses only what Core makes public — no
        // `@testable` — so a plain release build still compiles, and it stays below the app: what
        // needs `AiTerm` (ScriptedPrompter, the controller's test init) lives in `AiTermTests`.
        .target(name: "AiTermTestSupport", dependencies: ["AiTermCore"], path: "Tests/AiTermTestSupport"),
        .testTarget(name: "AiTermCoreTests", dependencies: ["AiTermCore", "AiTermTestSupport"], path: "Tests/AiTermCoreTests"),
        .testTarget(name: "AiTermUITests", dependencies: ["AiTermUI"], path: "Tests/AiTermUITests"),
        .testTarget(name: "AiTermTests", dependencies: ["AiTerm", "AiTermTestSupport"], path: "Tests/AiTermTests"),
    ],
    swiftLanguageModes: [.v6]
)
