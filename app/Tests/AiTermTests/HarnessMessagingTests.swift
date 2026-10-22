import Foundation
import Testing
import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// Messaging on Claude Code's and Codex's cards in Settings › Agents: one more check in the card's
/// look, the delivery check's verdict held against the version installed, and Run check while it is
/// what needs attention.
@MainActor
@Suite struct HarnessMessagingTests {
    private let model = AgentModel(id: "opus", label: "Opus", detail: nil, efforts: [], defaultEffort: nil)

    private func card(_ agent: AgentKind = .claude, integration: HarnessIntegrationState = .current,
                      cliAvailable: Bool = true) -> HarnessSnapshot {
        .reduce(agent: agent, cliAvailable: cliAvailable, integrationState: integration, models: [model],
                checks: [HarnessCheck(.cli, passed: cliAvailable, explanation: cliAvailable ? nil : "Not on the PATH."),
                         HarnessCheck(.integration, passed: integration == .current,
                                      explanation: integration == .current ? nil : "Driver is not installed.")])
    }

    @Test func readyMessagingIsAGreenChipAndTheCardStaysReady() {
        let shown = HarnessCardPresentation.snapshot(card(), messaging: .ready("Messaging ready for 2.1"))
        #expect(HarnessCardPresentation.chips(for: shown).map(\.label) == ["CLI", "Driver", "Messaging"])
        let chip = HarnessCardPresentation.chips(for: shown).last
        #expect(chip?.passed == true && chip?.explanation == "Messaging ready for 2.1")
        #expect(HarnessCardPresentation.status(for: shown) == SettingsStatus(.ready, "Ready"))
        #expect(HarnessCardPresentation.action(for: shown) == "Reinstall")
    }

    @Test func eachStateSaysWhyInTheStatusLine() {
        for sentence in ["Messaging not checked for 2.2", "Messaging failed: approvalRace", "Messaging not checked: version unknown"] {
            let shown = HarnessCardPresentation.snapshot(card(), messaging: .needsAttention(sentence))
            #expect(HarnessCardPresentation.status(for: shown) == SettingsStatus(.attention, sentence))
            #expect(HarnessCardPresentation.chips(for: shown).last?.passed == false)
        }
    }

    /// Run check only while Messaging is what needs attention: a missing driver is Install's first.
    @Test func runCheckIsTheActionOnlyWhileMessagingNeedsAttention() {
        let notChecked = DeliveryReadiness.needsAttention("Messaging not checked for 2.1")
        #expect(HarnessCardPresentation.action(for: HarnessCardPresentation.snapshot(card(), messaging: notChecked)) == "Run check")
        #expect(HarnessCardPresentation.runCheck == "Run check")
        let noDriver = HarnessCardPresentation.snapshot(card(integration: .missing), messaging: notChecked)
        #expect(HarnessCardPresentation.action(for: noDriver) == "Install")
        #expect(HarnessCardPresentation.status(for: noDriver).text == "Driver is not installed", "the driver's problem first")
        let ready = HarnessCardPresentation.snapshot(card(), messaging: .ready("Messaging ready for 2.1"))
        #expect(HarnessCardPresentation.action(for: ready) != "Run check")
    }

    /// No Messaging on a card whose CLI is missing, nor on an agent the check does not cover, nor before it is read.
    @Test func messagingIsLeftOutWhereItSaysNothing() {
        let absent = card(cliAvailable: false)
        #expect(HarnessCardPresentation.snapshot(absent, messaging: .needsAttention("Messaging not checked for 2.1")) == absent)
        #expect(HarnessCardPresentation.snapshot(card(.pi), messaging: nil) == card(.pi))
    }

    /// A Run check whose window couldn't open says why on the card, and offers Run check again.
    @Test func aRunCheckThatFailedSaysWhy() {
        let shown = HarnessCardPresentation.snapshot(card(), messaging: .needsAttention("Messaging not checked for 2.1"),
                                                     runFailure: "AiTerm’s helper isn’t running, so the check can’t open its window")
        #expect(HarnessCardPresentation.status(for: shown).text == "AiTerm’s helper isn’t running, so the check can’t open its window")
        #expect(HarnessCardPresentation.action(for: shown) == "Run check")
    }

    /// While Run check's window works, the card says so in place of the last verdict.
    @Test func aRunningCheckSaysSo() {
        let shown = HarnessCardPresentation.snapshot(card(), messaging: .needsAttention("Messaging failed: startupPaste"), running: true)
        #expect(HarnessCardPresentation.status(for: shown) == SettingsStatus(.attention, HarnessCardPresentation.checkRunning))
        #expect(HarnessCardPresentation.action(for: shown) == "Run check", "run again, in place of the window")
        let passed = HarnessCardPresentation.snapshot(card(), messaging: .ready("Messaging ready for 2.1"), running: true)
        #expect(HarnessCardPresentation.status(for: passed) == SettingsStatus(.ready, "Ready"))
    }

    // -- the checks, read and run ---------------------------------------------------------------

    private func scratchPolicy() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-messaging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("delivery-policy.json")
    }

    private func write(_ json: String, to url: URL) throws { try Data(json.utf8).write(to: url, options: .atomic) }

    private static let claudePassed = #"{"claude": {"version": "2.1.301", "pasteSafe": true, "submitSafe": true, "scenarios": {}}}"#

    @Test func itReadsTheFileAndTheVersions() async throws {
        let url = try scratchPolicy()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let checks = MessagingChecks(policyURL: url, versions: { _ in [.claude: "2.1.305", .codex: "0.160.0"] })
        #expect(checks.readiness(of: .claude) == nil, "nothing read yet")
        await checks.refresh()
        #expect(checks.readiness(of: .claude) == .needsAttention("Messaging not checked for 2.1"))
        #expect(checks.iterm == .needsAttention("iTerm2 checks not run"))
        try write(Self.claudePassed, to: url)
        await checks.refresh()
        #expect(checks.readiness(of: .claude) == .ready("Messaging ready for 2.1"))
        #expect(checks.readiness(of: .codex) == .needsAttention("Messaging not checked for 0.160"))
        #expect(checks.readiness(of: .pi) == nil)
    }

    /// A check run by hand reaches the card while Settings is open.
    @Test func aWatchSeesTheFileChange() async throws {
        let url = try scratchPolicy()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let checks = MessagingChecks(policyURL: url, versions: { _ in [.claude: "2.1.301"] }, interval: .milliseconds(20))
        let watching = Task { await checks.watch() }
        defer { watching.cancel() }
        #expect(await eventually(describing: "the first read") { checks.readiness(of: .claude) != nil })
        try write(Self.claudePassed, to: url)
        #expect(await eventually(describing: "the pass read") { checks.readiness(of: .claude)?.isReady == true })
    }

    @Test func runCheckOpensTheChecksWindowInFront() async throws {
        let url = try scratchPolicy()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let daemon = RecordingDaemon()
        var activated = 0
        let runtime = HelperLink.Runtime(python: URL(fileURLWithPath: "/usr/bin/python3"),
                                         daemonDir: URL(fileURLWithPath: "/Applications/AiTerm.app/Contents/Resources/daemon"))
        let checks = MessagingChecks(policyURL: url, versions: { _ in [.claude: "2.1.301"] })
        checks.opener = .init(daemon: { daemon }, runtime: { runtime }, frame: { Frame(x: 0, y: 0, w: 800, h: 600) },
                              activateIterm: { activated += 1 })
        await checks.refresh()
        await checks.run(.codex)
        let created = try #require(daemon.requests("window.createTask").last?.params)
        #expect(created["cwd"] as? String == runtime.daemonDir.path)
        let command = created["agentCommand"] as? String
        #expect(command == DeliveryCheck.command(agent: .codex, file: .missing, python: runtime.python, daemonDir: runtime.daemonDir))
        #expect(command?.hasSuffix("--agents codex --write && exit") == true, "iTerm2's own checks too: none passed yet")
        #expect(created["background"] == nil, "in front")
        #expect((created["taskId"] as? String)?.hasPrefix("delivery-check-codex-") == true, "a tag no row takes")
        #expect(daemon.requests("window.activate").map { $0.params["windowId"] as? String } == ["reopened"])
        #expect(activated == 1)
        #expect(checks.failures.isEmpty)

        // Run again: the last window closes first, and the new one opens in its place.
        await checks.run(.codex)
        #expect(daemon.requests("window.close").map { $0.params["windowId"] as? String } == ["reopened"])
        #expect(daemon.requests("window.createTask").count == 2)
        #expect(checks.windows == ["reopened-2": .codex])
    }

    /// Running from the window opening until the check writes the file, even the same verdicts again.
    @Test func aCheckRunsUntilItWritesTheFile() async throws {
        let url = try scratchPolicy()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let failed = #"{"claude": {"version": "2.1.301", "pasteSafe": false, "submitSafe": false, "checkedAt": "%@", "scenarios": {}}}"#
        try write(failed.replacingOccurrences(of: "%@", with: "2026-10-21T07:40:16Z"), to: url)
        let checks = MessagingChecks(policyURL: url, versions: { _ in [.claude: "2.1.301"] })
        checks.opener = .init(daemon: { RecordingDaemon() }, runtime: { HelperLink.Runtime(python: URL(fileURLWithPath: "/p"), daemonDir: URL(fileURLWithPath: "/d")) },
                              frame: { Frame(x: 0, y: 0, w: 800, h: 600) }, activateIterm: {})
        await checks.refresh()
        #expect(!checks.isRunning(.claude))
        await checks.run(.claude)
        #expect(checks.isRunning(.claude))
        #expect(!checks.isRunning(.codex))
        try write(failed.replacingOccurrences(of: "%@", with: "2026-10-21T08:12:00Z"), to: url)
        await checks.refresh(force: true)
        #expect(!checks.isRunning(.claude), "written, though it failed the same way")
    }

    /// Why the last run failed, for the card's details, while that run's verdict is the card's.
    @Test func theCardKeepsWhyTheLastRunFailed() async throws {
        let url = try scratchPolicy()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try write(#"{"codex": {"version": "0.163.0", "pasteSafe": false, "submitSafe": false, "failedAt": "menuPaste", "failure": "The /model menu did not open.", "scenarios": {}}}"#, to: url)
        let checks = MessagingChecks(policyURL: url, versions: { _ in [.codex: "0.163.0", .claude: "2.1.301"] })
        await checks.refresh()
        #expect(checks.failure(of: .codex) == "The /model menu did not open.")
        #expect(checks.failure(of: .claude) == nil)
    }

    @Test func aClosedWindowRunsNoMore() async throws {
        let checks = MessagingChecks.inert()
        checks.opener = .init(daemon: { RecordingDaemon() }, runtime: { HelperLink.Runtime(python: URL(fileURLWithPath: "/p"), daemonDir: URL(fileURLWithPath: "/d")) },
                              frame: { Frame(x: 0, y: 0, w: 800, h: 600) }, activateIterm: {})
        await checks.run(.claude)
        #expect(checks.isRunning(.claude))
        checks.windowClosed(try #require(checks.windows.keys.first))
        #expect(!checks.isRunning(.claude))
    }

    @Test func aWindowTheHelperRefusedSaysWhy() async {
        let daemon = RecordingDaemon(failing: ["window.createTask": .itermUnavailable])
        let checks = MessagingChecks.inert()
        checks.opener = .init(daemon: { daemon }, runtime: { HelperLink.Runtime(python: URL(fileURLWithPath: "/p"), daemonDir: URL(fileURLWithPath: "/d")) },
                              frame: { Frame(x: 0, y: 0, w: 800, h: 600) }, activateIterm: {})
        await checks.run(.claude)
        #expect(checks.failures[.claude] != nil)
        #expect(checks.windows.isEmpty)
    }

    @Test func runCheckWithNoHelperSaysSo() async {
        let checks = MessagingChecks.inert()
        await checks.run(.claude)
        #expect(checks.failures[.claude] == "AiTerm’s helper isn’t running, so the check can’t open its window")
    }

    /// Its window closing reads the file again, whatever its stamp says.
    @Test func theChecksWindowClosingReadsTheFileAgain() async throws {
        let url = try scratchPolicy()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let daemon = RecordingDaemon()
        let checks = MessagingChecks(policyURL: url, versions: { _ in [.claude: "2.1.301"] })
        checks.opener = .init(daemon: { daemon }, runtime: { HelperLink.Runtime(python: URL(fileURLWithPath: "/p"), daemonDir: URL(fileURLWithPath: "/d")) },
                              frame: { Frame(x: 0, y: 0, w: 800, h: 600) }, activateIterm: {})
        await checks.refresh()
        await checks.run(.claude)
        let window = try #require(checks.windows.keys.first)
        try write(Self.claudePassed, to: url)
        checks.windowClosed("another window")
        checks.windowClosed(window)
        #expect(checks.windows.isEmpty)
        #expect(await eventually(describing: "read again") { checks.readiness(of: .claude)?.isReady == true })
    }
}
