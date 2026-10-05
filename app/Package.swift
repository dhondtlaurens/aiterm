// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "AiTerm",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "AiTermCore", path: "Sources/AiTermCore"),
        .target(name: "AiTermUI", path: "Sources/AiTermUI", exclude: ["README.md"]),
        .executableTarget(name: "AiTerm", dependencies: ["AiTermCore", "AiTermUI"], path: "Sources/AiTerm",
                          resources: [.copy("Resources")]),
        // Fakes and fixtures the Core and app tests share: test targets cannot share a source file, so
        // they live in a library the tests import (`@testable`, so debug builds only: release builds
        // name the `AiTerm` product, never this one). It stays below the app — what needs `AiTerm`
        // (ScriptedPrompter, the controller's test init) lives in `AiTermTests`.
        .target(name: "AiTermTestSupport", dependencies: ["AiTermCore"], path: "Tests/AiTermTestSupport"),
        .testTarget(name: "AiTermCoreTests", dependencies: ["AiTermCore", "AiTermTestSupport"], path: "Tests/AiTermCoreTests"),
        .testTarget(name: "AiTermUITests", dependencies: ["AiTermUI"], path: "Tests/AiTermUITests"),
        .testTarget(name: "AiTermTests", dependencies: ["AiTerm", "AiTermTestSupport"], path: "Tests/AiTermTests"),
    ],
    swiftLanguageModes: [.v6]
)
