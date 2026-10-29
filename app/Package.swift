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
        .target(name: "AiTermTestSupport", dependencies: ["AiTermCore", "AiTermTestWindowHook"], path: "Tests/AiTermTestSupport"),
        // Hides every window the test process orders in, so a run does not draw over the person's
        // apps. Only AiTermTestSupport depends on it: it is never linked into the app.
        .target(name: "AiTermTestWindowHook", path: "Tests/AiTermTestWindowHook",
                linkerSettings: [.linkedFramework("AppKit")]),
        // The Operator evals' baseline (Fixtures/) is read by path from the checkout, not as a resource bundle.
        .testTarget(name: "AiTermCoreTests", dependencies: ["AiTermCore", "AiTermTestSupport"], path: "Tests/AiTermCoreTests",
                    exclude: ["Operators/Fixtures"]),
        .testTarget(name: "AiTermUITests", dependencies: ["AiTermUI", "AiTermTestSupport"], path: "Tests/AiTermUITests"),
        .testTarget(name: "AiTermTests", dependencies: ["AiTerm", "AiTermTestSupport"], path: "Tests/AiTermTests",
                    exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
