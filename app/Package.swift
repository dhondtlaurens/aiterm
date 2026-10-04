// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "AiTerm",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "AiTermCore", path: "Sources/AiTermCore",
                linkerSettings: [.linkedFramework("CoreWLAN"), .linkedFramework("IOKit"), .linkedFramework("CoreLocation")]),
        .target(name: "AiTermUI", path: "Sources/AiTermUI", exclude: ["README.md"]),
        .executableTarget(name: "AiTerm", dependencies: ["AiTermCore", "AiTermUI"], path: "Sources/AiTerm",
                          resources: [.copy("Resources")]),
        .testTarget(name: "AiTermCoreTests", dependencies: ["AiTermCore"], path: "Tests/AiTermCoreTests"),
        .testTarget(name: "AiTermUITests", dependencies: ["AiTermUI"], path: "Tests/AiTermUITests"),
        .testTarget(name: "AiTermTests", dependencies: ["AiTerm"], path: "Tests/AiTermTests"),
    ],
    swiftLanguageModes: [.v6]
)
