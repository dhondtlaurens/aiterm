import Foundation
import Synchronization
import Testing
@testable import AiTermCore

@Suite struct HarnessDiagnosticsTests {
    private let model = AgentModel(id: "openai/model-x", label: "openai / model-x", detail: nil,
                                   efforts: ["high"], defaultEffort: "high")

    @Test func harnessHealthHasExactlyThreeOutcomes() {
        #expect(HarnessSnapshot.reduce(agent: .pi, cliAvailable: false, integrationState: .notChecked,
                                       models: []).health == .unavailable)
        #expect(HarnessSnapshot.reduce(agent: .pi, cliAvailable: true, integrationState: .missing,
                                       models: [model]).health == .warning)
        let providerCheck = HarnessCheck(.models, passed: false,
                                         explanation: "No PI providers are signed in.")
        #expect(HarnessSnapshot.reduce(agent: .pi, cliAvailable: true, integrationState: .current,
                                       models: [], checks: [providerCheck]).health == .warning)
        #expect(HarnessSnapshot.reduce(agent: .pi, cliAvailable: true, integrationState: .current,
                                       models: [model]).health == .ready)
        for state in [HarnessIntegrationState.missing, .current, .outdated, .invalidOwned] {
            #expect(HarnessSnapshot.reduce(agent: .pi, cliAvailable: true, integrationState: state,
                                           models: [model]).canInstall)
        }
        for state in [HarnessIntegrationState.foreign, .unreadable, .resourceUnavailable, .notChecked] {
            #expect(!HarnessSnapshot.reduce(agent: .pi, cliAvailable: true, integrationState: state,
                                            models: [model]).canInstall)
        }
    }

    @Test func aFailedTestIsWarningWithItsFirstExplanation() {
        let checks = [
            HarnessCheck(.cli, passed: true, explanation: nil),
            HarnessCheck(.delivery, passed: false,
                         explanation: "AiTerm did not receive the test event."),
            HarnessCheck(.models, passed: false,
                         explanation: "The model catalogue is unavailable."),
        ]
        let snapshot = HarnessSnapshot.reduce(agent: .pi, cliAvailable: true,
                                              integrationState: .current, models: [model], checks: checks)
        #expect(snapshot.health == .warning)
        #expect(snapshot.summary == "AiTerm did not receive the test event.")
    }

    @Test func piProbeCachesTheLastSuccessfulCatalogueAsStaleAfterFailure() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let source = "// AiTerm PI extension schema: \(PiDriver.schemaVersion)\nexport default function aiterm() {}\n"
        try PiDriver(home: home, daemonPort: 47821, source: source).install()
        let results = CommandResults([
            ProcessOutput(status: 0,
                                 stdout: "provider model context max-out thinking images\nopenai model-x 128k 16k yes no\n",
                                 stderr: "", timedOut: false),
            ProcessOutput(status: 1, stdout: "", stderr: "offline failure", timedOut: false),
        ])
        let runner = HarnessCommandRunner(locate: { _ in "/usr/bin/true" },
                                          run: { _, _, _, _ in results.next() })
        let service = HarnessService(home: home, daemonPort: 47821, runner: runner,
                                     resources: HarnessResources([.claude: "/usr/bin/true", .pi: source], installationAllowed: true,
                                                                 unavailableReason: nil))

        let current = await service.probe(.pi)
        #expect(current.health == .ready)
        #expect(current.models.map(\.id) == ["openai/model-x"])
        let stale = await service.probe(.pi)
        #expect(stale.health == .warning)
        #expect(stale.models == current.models)
        #expect(stale.modelsAreStale)
    }

    /// A directory carries the execute bit, so `FileManager.isExecutableFile` alone takes a
    /// directory named like the CLI — a stale `pi` folder on the PATH — for the CLI itself.
    @Test func aDirectoryWhereTheCLIShouldBeIsNoCLI() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-harness-dir-\(UUID().uuidString)")
        let folder = home.appendingPathComponent("bin/pi")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = HarnessCommandRunner(locate: { _ in folder.path },
                                          run: { _, _, _, _ in ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false) })
        let service = HarnessService(home: home, daemonPort: 47821, runner: runner,
                                     resources: HarnessResources([.claude: "/usr/bin/true"],
                                                                 installationAllowed: true, unavailableReason: nil))
        #expect(await service.probe(.pi).health == .unavailable)
    }

    /// The CLI was already located and executable when the catalogue launch fails, so the failure
    /// is a warning on the models check — never an "Unavailable" card whose actions disappear.
    @Test func piLaunchFailureIsAWarningThatKeepsTheStaleCatalogue() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-harness-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let source = "// AiTerm PI extension schema: \(PiDriver.schemaVersion)\nexport default function aiterm() {}\n"
        try PiDriver(home: home, daemonPort: 47821, source: source).install()
        let attempts = CallCounter()
        let runner = HarnessCommandRunner(locate: { _ in "/usr/bin/true" }, run: { _, _, _, _ in
            attempts.increment()
            guard attempts.value == 1 else { throw CocoaError(.fileReadUnknown) }
            return ProcessOutput(status: 0,
                                        stdout: "provider model context max-out thinking images\nopenai model-x 128k 16k yes no\n",
                                        stderr: "", timedOut: false)
        })
        let service = HarnessService(home: home, daemonPort: 47821, runner: runner,
                                     resources: HarnessResources([.claude: "/usr/bin/true", .pi: source], installationAllowed: true,
                                                                 unavailableReason: nil))

        let current = await service.probe(.pi)
        #expect(current.health == .ready)
        let failed = await service.probe(.pi)
        #expect(failed.health == .warning)
        #expect(failed.checks.first { $0.id == .cli }?.passed == true)
        #expect(failed.models == current.models)
        #expect(failed.modelsAreStale)
        #expect(failed.summary == "PI couldn’t be launched.")
    }

    @Test func piLaunchFailureWithoutAPriorCatalogueIsStillNotUnavailable() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-harness-launch-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let source = "// AiTerm PI extension schema: \(PiDriver.schemaVersion)\nexport default function aiterm() {}\n"
        try PiDriver(home: home, daemonPort: 47821, source: source).install()
        let runner = HarnessCommandRunner(locate: { _ in "/usr/bin/true" },
                                          run: { _, _, _, _ in throw CocoaError(.fileReadUnknown) })
        let service = HarnessService(home: home, daemonPort: 47821, runner: runner,
                                     resources: HarnessResources([.claude: "/usr/bin/true", .pi: source], installationAllowed: true,
                                                                 unavailableReason: nil))

        let snapshot = await service.probe(.pi)
        #expect(snapshot.health == .warning)
        #expect(snapshot.checks.first { $0.id == .cli }?.passed == true)
        #expect(snapshot.models.isEmpty)
        #expect(!snapshot.modelsAreStale)
        #expect(snapshot.summary == "PI couldn’t be launched.")
    }

    @Test func everyHarnessCallsItsIntegrationADriver() async throws {
        // Hooks for Claude and Codex, an extension for PI: to the user each is the same thing,
        // the piece AiTerm installs so the harness can report back, and Settings names it once.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-harness-driver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = HarnessCommandRunner(locate: { _ in "/usr/bin/true" }, run: { _, _, _, _ in
            ProcessOutput(status: 0,
                                 stdout: "provider model context max-out thinking images\nopenai model-x 128k 16k yes no\n",
                                 stderr: "", timedOut: false)
        })
        let service = HarnessService(home: home, daemonPort: 47821, runner: runner,
                                     resources: HarnessResources([.claude: "/usr/bin/true", .pi: "// AiTerm PI extension schema: \(PiDriver.schemaVersion)\n", .grok: "/usr/bin/true"],
                                                                 installationAllowed: true,
                                                                 unavailableReason: nil))
        for agent in AgentKind.allCases {
            let snapshot = await service.probe(agent)
            let integration = try #require(snapshot.checks.first { $0.id == .integration })
            #expect(integration.label == "Driver")
            #expect(snapshot.summary == "Driver is not installed.")
        }
        let unchecked = HarnessSnapshot.reduce(agent: .pi, cliAvailable: true, integrationState: .outdated,
                                               models: [model])
        #expect(unchecked.summary == "Driver is out of date.")
    }

    @Test func piInstallIsExplicitAndReprobesTheOwnedExtension() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let source = "// AiTerm PI extension schema: \(PiDriver.schemaVersion)\nexport default function aiterm() {}\n"
        let runner = HarnessCommandRunner(locate: { _ in "/usr/bin/true" }, run: { _, _, _, _ in
            ProcessOutput(status: 0,
                                 stdout: "provider model context max-out thinking images\nopenai model-x 128k 16k yes no\n",
                                 stderr: "", timedOut: false)
        })
        let service = HarnessService(home: home, daemonPort: 47821, runner: runner,
                                     resources: HarnessResources([.claude: "/usr/bin/true", .pi: source], installationAllowed: true,
                                                                 unavailableReason: nil))

        let before = await service.probe(.pi)
        #expect(before.canInstall)
        #expect(PiDriver(home: home, daemonPort: 47821, source: source).state == .missing)
        let after = try await service.install(.pi)
        #expect(after.health == .ready)
        #expect(PiDriver(home: home, daemonPort: 47821, source: source).state == .current)

        // Install again over the working extension: it is overwritten, not refused.
        let again = try await service.install(.pi)
        #expect(again.health == .ready)
        #expect(PiDriver(home: home, daemonPort: 47821, source: source).state == .current)
    }

    @Test func corruptedCurrentVersionPiExtensionCanBeReinstalled() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-harness-pi-corrupt-\(UUID().uuidString)")
        let source = "// AiTerm PI extension schema: \(PiDriver.schemaVersion)\nexport default function aiterm() {}\n"
        let target = home.appendingPathComponent(PiDriver.path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "// AiTerm PI extension schema: \(PiDriver.schemaVersion)\ntruncated\n"
            .write(to: target, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = HarnessCommandRunner(locate: { _ in "/usr/bin/true" }, run: { _, _, _, _ in
            ProcessOutput(status: 0,
                                 stdout: "provider model context max-out thinking images\nopenai model-x 128k 16k yes no\n",
                                 stderr: "", timedOut: false)
        })
        let service = HarnessService(home: home, daemonPort: 47821, runner: runner,
                                     resources: HarnessResources([.claude: "/usr/bin/true", .pi: source], installationAllowed: true,
                                                                 unavailableReason: nil))

        let snapshot = await service.probe(.pi)
        #expect(snapshot.integrationState == .invalidOwned)
        #expect(snapshot.canInstall)
    }

    @Test func ownedStaleClaudeAndCodexIntegrationsCanBeReinstalled() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-harness-owned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let staleClaude: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["_aiterm": true, "url": "http://127.0.0.1:1/hook/claude"]]]]],
            "statusLine": ["type": "command", "command": "/usr/bin/true"],
        ]
        try JSONSerialization.data(withJSONObject: staleClaude)
            .write(to: home.appendingPathComponent(".claude/settings.json"))
        try "\(CodexHookConfig.begin)\nold owned block\n\(CodexHookConfig.end)\n"
            .write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)

        let runner = HarnessCommandRunner(locate: { _ in "/usr/bin/true" }, run: { _, _, _, _ in
            ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false)
        })
        let service = HarnessService(home: home, daemonPort: 47821, runner: runner,
                                     resources: HarnessResources([.claude: "/usr/bin/true"], installationAllowed: true,
                                                                 unavailableReason: nil))

        let claude = await service.probe(.claude)
        let codex = await service.probe(.codex)
        #expect(claude.integrationState == .outdated)
        #expect(claude.canInstall)
        #expect(codex.integrationState == .outdated)
        #expect(codex.canInstall)
    }

    @Test func harnessTestSkipsMissingIntegrationAndTurnsFailedDeliveryIntoWarning() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-harness-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let calls = CallCounter()
        let transport = HarnessTestTransport { _, body, _ in
            calls.increment()
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
            if let id = object?["_aiterm_daemon_test_id"] {
                return try JSONSerialization.data(withJSONObject: ["ok": true, "daemonTestId": id])
            }
            return try JSONSerialization.data(withJSONObject: ["ok": true, "testId": "wrong"])
        }
        let runner = HarnessCommandRunner(locate: { _ in "/usr/bin/true" }, run: { _, _, _, _ in
            ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false)
        })
        let resources = HarnessResources([.claude: "/usr/bin/true"], installationAllowed: true, unavailableReason: nil)
        let service = HarnessService(home: home, daemonPort: 47821, runner: runner,
                                     resources: resources, testTransport: transport)

        let missing = await service.test(await service.probe(.codex))
        #expect(missing.integrationState == .missing)
        #expect(calls.value == 0)

        try CodexDriver(home: home, daemonPort: 47821).install()
        let failed = await service.test(await service.probe(.codex))
        #expect(failed.health == .warning)
        #expect(failed.summary == "AiTerm did not receive the test event.")
        #expect(calls.value == 2)
    }
}

extension HarnessDiagnosticsTests {
    /// A PI probe found the CLI, then the catalogue looked for it again; a Test probed all over.
    @Test func aProbeLocatesOnceAndATestNotAtAll() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-harness-locate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let source = "// AiTerm PI extension schema: \(PiDriver.schemaVersion)\nexport default function aiterm() {}\n"
        try PiDriver(home: home, daemonPort: 47821, source: source).install()
        let lookups = CallCounter()
        let runner = HarnessCommandRunner(locate: { _ in lookups.increment(); return "/usr/bin/true" }, run: { _, arguments, environment, _ in
            let id = environment["AITERM_INTEGRATION_TEST"] ?? ""
            return arguments.contains("--list-models")
                ? ProcessOutput(status: 0, stdout: "provider model context max-out thinking images\nopenai model-x 128k 16k yes no\n", stderr: "", timedOut: false)
                : ProcessOutput(status: 0, stdout: "", stderr: "AITERM_INTEGRATION_TEST_OK=\(id)\n", timedOut: false)
        })
        let transport = HarnessTestTransport { _, body, _ in
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
            return try JSONSerialization.data(withJSONObject: ["ok": true, "daemonTestId": object?["_aiterm_daemon_test_id"] ?? ""])
        }
        let service = HarnessService(home: home, daemonPort: 47821, runner: runner,
                                     resources: HarnessResources([.claude: "/usr/bin/true", .pi: source],
                                                                 installationAllowed: true, unavailableReason: nil),
                                     testTransport: transport)

        let probed = await service.probe(.pi)
        #expect(probed.health == .ready)
        #expect(lookups.value == 1)
        let tested = await service.test(probed)
        #expect(tested.checks.first { $0.id == .delivery }?.passed == true)
        #expect(lookups.value == 2, "only the Test's own launch of PI looks for it")
    }
}

extension HarnessDiagnosticsTests {
    private static let piTable = "provider model context max-out thinking images\nopenai model-x 128k 16k yes no\n"

    private func piHome() throws -> (home: URL, resources: HarnessResources) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-harness-pool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = "// AiTerm PI extension schema: \(PiDriver.schemaVersion)\nexport default function aiterm() {}\n"
        try PiDriver(home: home, daemonPort: 47821, source: source).install()
        return (home, HarnessResources([.claude: "/usr/bin/true", .pi: source], installationAllowed: true, unavailableReason: nil))
    }

    /// Installing the driver changes nothing about which models PI lists, so the install's last
    /// probe reuses the catalogue its first one read: one `pi --list-models` per install.
    @Test func anInstallListsPiModelsOnce() async throws {
        for cliPresent in [true, false] {
            let (home, resources) = try piHome()
            defer { try? FileManager.default.removeItem(at: home) }
            try FileManager.default.removeItem(at: home.appendingPathComponent(PiDriver.path))
            let listings = CallCounter(), installed = CallCounter()
            let runner = HarnessCommandRunner(locate: { _ in cliPresent || installed.value > 0 ? "/usr/bin/true" : nil },
                                              run: { executable, arguments, _, _ in
                if executable == "/bin/zsh" { installed.increment() }
                if arguments.contains("--list-models") { listings.increment() }
                return ProcessOutput(status: 0, stdout: Self.piTable, stderr: "", timedOut: false)
            })
            let service = HarnessService(home: home, daemonPort: 47821, runner: runner, resources: resources)
            let snapshot = try await service.install(.pi)
            #expect(snapshot.health == .ready)
            #expect(snapshot.models.map(\.id) == ["openai/model-x"])
            #expect(listings.value == 1, "CLI present: \(cliPresent)")
        }
    }

    /// The actor ran its CLIs itself: a PI catalogue launch (or a ten-minute install) parked a
    /// cooperative thread and queued every other card's probe behind it.
    @Test func aBlockedPiLaunchDoesNotHoldUpAnotherAgentsProbe() async throws {
        let (home, resources) = try piHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let runner = HarnessCommandRunner(locate: { _ in "/usr/bin/true" }, run: { _, arguments, _, _ in
            if arguments.contains("--list-models") { started.signal(); _ = release.wait(timeout: .now() + 5) }
            return ProcessOutput(status: 0, stdout: Self.piTable, stderr: "", timedOut: false)
        })
        let service = HarnessService(home: home, daemonPort: 47821, runner: runner, resources: resources)

        let pi = Task { await service.probe(.pi) }
        _ = await BackgroundWork.run { started.wait(timeout: .now() + 5) }
        let clock = ContinuousClock(), begun = clock.now
        _ = await service.probe(.codex)
        let waited = clock.now - begun
        release.signal()
        #expect(await pi.value.health == .ready)
        // PI's launch is held for five seconds: a bound under that still catches the wait, with
        // room for a loaded machine.
        #expect(waited < .seconds(4), "the Codex probe waited \(waited) for PI's launch")
    }

    /// The actor is reentrant across a launch now, so two probes of one agent can overlap: the
    /// older one finishing last must not replace the catalogue the newer one found.
    @Test func anOlderProbeFinishingLastKeepsTheNewerCatalogue() async throws {
        let (home, resources) = try piHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let launches = CallCounter()
        let runner = HarnessCommandRunner(locate: { _ in "/usr/bin/true" }, run: { _, _, _, _ in
            launches.increment()
            switch launches.value {
            case 1:
                started.signal(); _ = release.wait(timeout: .now() + 5)
                return ProcessOutput(status: 0, stdout: Self.piTable.replacingOccurrences(of: "model-x", with: "older"), stderr: "", timedOut: false)
            case 2: return ProcessOutput(status: 0, stdout: Self.piTable, stderr: "", timedOut: false)
            default: return ProcessOutput(status: 1, stdout: "", stderr: "offline", timedOut: false)
            }
        })
        let service = HarnessService(home: home, daemonPort: 47821, runner: runner, resources: resources)

        let older = Task { await service.probe(.pi) }
        _ = await BackgroundWork.run { started.wait(timeout: .now() + 5) }
        let newer = await service.probe(.pi)
        release.signal()
        _ = await older.value
        let stale = await service.probe(.pi)
        #expect(stale.modelsAreStale)
        #expect(stale.models == newer.models)
        #expect(stale.models.map(\.id) == ["openai/model-x"])
    }
}

/// Unchecked because its stored `var`s are mutable: every access holds `lock`.
private final class CommandResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ProcessOutput]

    init(_ results: [ProcessOutput]) { self.results = results }

    func next() -> ProcessOutput {
        lock.withLock { results.isEmpty ? ProcessOutput(status: 1, stdout: "", stderr: "empty", timedOut: false) : results.removeFirst() }
    }
}

private final class CallCounter: Sendable {
    private let count = Mutex(0)

    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}
