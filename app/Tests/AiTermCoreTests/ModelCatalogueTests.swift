import Foundation
import Synchronization
import Testing
@testable import AiTermCore

@Suite struct ModelCatalogueTests {
    private static let piTable = "provider model context max-out thinking images\nopenai model-x 128k 16k yes no\n"

    private func scratchHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-catalogue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// A PI that lists `piTable`, or fails as told, and counts its launches. `/usr/bin/true` is
    /// where it is found: a real file, so its stamp is a real one.
    private func pi(_ launches: Launches, failing: Bool = false) -> HarnessCommandRunner {
        HarnessCommandRunner(locate: { $0 == "pi" ? "/usr/bin/true" : nil }, run: { _, arguments, _, _ in
            #expect(arguments == ["--offline", "--list-models"])
            launches.count()
            return launches.failing ? ProcessOutput(status: 1, stdout: "", stderr: "Loading…\nNo API key for openai\n", timedOut: false)
                : ProcessOutput(status: 0, stdout: Self.piTable, stderr: "", timedOut: false)
        })
    }

    /// Each sheet opening and each agent switch used to launch PI. Now a list read stands while
    /// PI's sign-ins, its custom models and the CLI itself are unchanged.
    @Test func piIsLaunchedOnceUntilItsConfigurationChanges() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let launches = Launches()
        let catalogue = ModelCatalogue(home: home, runner: pi(launches))

        for _ in 0..<3 { #expect(try catalogue.models(for: .pi).map(\.id) == ["openai/model-x"]) }
        _ = try catalogue.models(for: .claude)
        #expect(launches.value == 1)

        let agent = home.appendingPathComponent(".pi/agent")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: agent.appendingPathComponent("auth.json"))
        _ = try catalogue.models(for: .pi)
        #expect(launches.value == 2, "a sign-in changes what PI lists")
        _ = try catalogue.models(for: .pi)
        #expect(launches.value == 2)

        _ = catalogue.read(.pi, refreshing: true)
        #expect(launches.value == 3, "Settings' probe checks that PI still launches")
    }

    /// PI's failure is said, not swallowed into an empty list: the sheet shows it in place of the
    /// models. Once a list has been read, a failed read again offers that one, marked stale.
    @Test func aFailedPiReadSaysWhyAndIsNeverKept() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let launches = Launches(failing: true)
        let catalogue = ModelCatalogue(home: home, runner: pi(launches))

        #expect(throws: PiModelCatalogError.failed(1, "Loading…\nNo API key for openai")) { try catalogue.models(for: .pi) }
        #expect(catalogue.read(.pi) == ModelCatalogue.Reading(models: [], failure: .failed(1, "Loading…\nNo API key for openai")))
        #expect(launches.value == 2, "a failure is not an answer to keep")
        #expect(PiModelCatalogError.failed(1, "Loading…\nNo API key for openai\n").localizedDescription
                == "The PI model catalogue is unavailable: No API key for openai")
        #expect(PiModelCatalogError.unavailable.localizedDescription == "PI couldn’t be launched.")

        launches.failing = false
        let listed = try catalogue.models(for: .pi)
        launches.failing = true
        let reading = catalogue.read(.pi, refreshing: true)
        #expect(reading.models == listed && reading.stale)
        #expect(reading.explanation == "The PI model catalogue couldn’t be refreshed.")
        #expect(try catalogue.models(for: .pi) == listed, "unchanged files: the list read stands")
    }

    /// A missing CLI is a failure like a failed launch, and launches nothing.
    @Test func aMissingPiIsUnavailable() {
        let catalogue = ModelCatalogue(home: FileManager.default.temporaryDirectory, runner: .nothingInstalled)
        #expect(catalogue.read(.pi) == ModelCatalogue.Reading(models: [], failure: .unavailable))
    }

    /// A file catalogue is read once and then stands until one of its files changes: rewritten in
    /// place with its size and date kept, the cached list still answers; given a new date, the
    /// file is read again.
    @Test func aFileCatalogueStandsUntilAFileChanges() throws {
        let home = try scratchHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dated = Date(timeIntervalSince1970: 1_800_000_000)
        try Data(#"model = "gpt-a""#.utf8).write(to: config)
        try FileManager.default.setAttributes([.modificationDate: dated], ofItemAtPath: config.path)
        let catalogue = ModelCatalogue(home: home, runner: .nothingInstalled)
        #expect(try catalogue.models(for: .codex).map(\.id) == ["gpt-a"])

        let handle = try FileHandle(forWritingTo: config)
        try handle.write(contentsOf: Data(#"model = "gpt-b""#.utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: dated], ofItemAtPath: config.path)
        #expect(try catalogue.models(for: .codex).map(\.id) == ["gpt-a"], "nothing a stat sees has changed")

        try FileManager.default.setAttributes([.modificationDate: dated.addingTimeInterval(1)], ofItemAtPath: config.path)
        #expect(try catalogue.models(for: .codex).map(\.id) == ["gpt-b"])

        // A file that appears is a change like any other.
        try Data(#"{"models":[{"slug":"gpt-c","display_name":"C"}]}"#.utf8)
            .write(to: home.appendingPathComponent(".codex/models_cache.json"))
        #expect(try catalogue.models(for: .codex).map(\.id) == ["gpt-c"])
    }
}

private final class Launches: Sendable {
    private let launched = Mutex(0)
    private let fails: Mutex<Bool>

    init(failing: Bool = false) { fails = Mutex(failing) }

    var value: Int { launched.withLock { $0 } }
    var failing: Bool {
        get { fails.withLock { $0 } }
        set { fails.withLock { $0 = newValue } }
    }

    func count() { launched.withLock { $0 += 1 } }
}
