import Foundation
import Synchronization
import Testing
@testable import AiTermCore

@Suite struct LoginShellLocatorTests {
    /// What a login shell prints for the locator's query on a machine with `found` installed, each
    /// at `/usr/bin/true`, and Python at `python`, after an rc file's banner.
    static func output(_ found: [AgentKind], python: String = "/usr/bin/python3") -> String {
        "Last login: Mon Oct  5 on ttys001\n" + AgentKind.allCases.map { agent in
            let path = found.contains(agent) ? "/usr/bin/true" : ""
            return "\(agent.rawValue)\t\(path)\n\(agent.rawValue)\t\(path)\n"
        }.joined() + LoginShellLocator.pythonMarker + "\n" + python + "\n"
    }

    /// The launch's agent probe and Python lookup, and then Settings' first opening, which probes
    /// every card at once. Before, each was a login shell of its own: two at launch and one per
    /// agent in Settings, six in all. Now they share one; a CLI that is missing is asked about
    /// again on the opening, but every missing one in the same shell.
    @Test func theLaunchAndTheFirstSettingsOpeningShareOneLoginShell() async throws {
        for missing in [[], [AgentKind.grok, .pi]] {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-locator-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: home) }
            let installed = AgentKind.allCases.filter { !missing.contains($0) }
            let shell = CountingShell(Self.output(installed))
            let locator = LoginShellLocator(shell: shell.run)

            async let agents = BackgroundWork.run { AgentAvailability.installed(locator: locator) }
            async let python = BackgroundWork.run { PythonLocator.find(locator: locator, validate: { _ in true }) }
            let (available, interpreter) = try await (agents, python)
            #expect(available == Set(installed))
            #expect(interpreter?.path == "/usr/bin/python3")
            #expect(shell.spawns == 1, "the launch's two lookups")

            let runner = HarnessCommandRunner(locate: { locator.locate($0) }, run: { _, _, _, _ in
                ProcessOutput(status: 0, stdout: "provider model context max-out thinking images\nopenai model-x 128k 16k yes no\n",
                              stderr: "", timedOut: false)
            }, forgetLocations: { locator.forget() })
            let service = HarnessService(home: home, daemonPort: 47821, runner: runner,
                                         resources: HarnessResources(claudeShimPath: nil, piExtensionSource: nil, grokShimPath: nil,
                                                                     installationAllowed: false, unavailableReason: "Not in a test."))
            let cards = await withTaskGroup(of: (AgentKind, Bool).self) { group in
                for agent in AgentKind.allCases { group.addTask { (agent, await service.probe(agent).health != .unavailable) } }
                return await group.reduce(into: [AgentKind: Bool]()) { $0[$1.0] = $1.1 }
            }
            #expect(cards == Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0, installed.contains($0)) }))
            #expect(shell.spawns == (missing.isEmpty ? 1 : 2), "missing: \(missing)")
        }
    }

    /// Callers who ask while the shell runs wait for it rather than starting their own.
    @Test func concurrentCallersShareOneShell() async throws {
        let shell = CountingShell(Self.output([.claude, .codex]))
        let locator = LoginShellLocator(shell: shell.run)
        let found = try await withThrowingTaskGroup(of: String?.self) { group in
            for name in ["claude", "codex", "grok", "pi", "claude", "codex"] {
                group.addTask { try await BackgroundWork.run { locator.locate(name) } }
            }
            return try await group.reduce(into: [String?]()) { $0.append($1) }
        }
        #expect(found.compactMap { $0 }.count == 4)
        #expect(shell.spawns == 1)
    }

    /// A found path stands for as long as it is an executable; a missing name asks again, and so
    /// does a path that no longer runs.
    @Test func aFoundPathStandsWhileItIsAnExecutable() {
        let shell = CountingShell(Self.output([.claude]), delay: 0)
        let executable = Mutex(true)
        let locator = LoginShellLocator(shell: shell.run, isExecutable: { _ in executable.withLock { $0 } })
        #expect(locator.locate("claude") == "/usr/bin/true")
        #expect(locator.locate("claude") == "/usr/bin/true")
        #expect(shell.spawns == 1)

        #expect(locator.locate("pi") == nil)
        #expect(locator.locate("pi") == nil)
        #expect(shell.spawns == 3, "a CLI installed from a terminal shows up on the next lookup")

        executable.withLock { $0 = false }
        _ = locator.locate("claude")
        #expect(shell.spawns == 4)
    }

    /// After an install, nothing found before is trusted: the CLI may now be somewhere else.
    @Test func forgettingAsksTheShellAgain() {
        let shell = CountingShell(Self.output([.claude]), delay: 0)
        let locator = LoginShellLocator(shell: shell.run)
        _ = locator.locate("claude")
        locator.forget()
        _ = locator.locate("claude")
        #expect(shell.spawns == 2)
    }

    /// A shell that failed or ran out of time said nothing, and is not kept as if it had.
    @Test func aShellThatFailedIsNotKept() {
        let shell = CountingShell(nil, delay: 0)
        let locator = LoginShellLocator(shell: shell.run)
        #expect(locator.locate("claude") == nil)
        #expect(locator.current() == nil)
        shell.answer(Self.output([.claude]))
        #expect(locator.locate("claude") == "/usr/bin/true")
        #expect(locator.current()?.executables == ["claude": "/usr/bin/true"])
        #expect(shell.spawns == 3)
    }

    /// Each half of the answer is read only by its own reader: a Python path is no agent, and an
    /// agent's line no interpreter.
    @Test func theQueryAnswersBothHalvesInZsh() throws {
        let locator = LoginShellLocator(names: ["sh", "missing"], shell: { query in
            let result = try? ProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"), ["-fc", "print banner; " + query], timeout: 5)
            return result?.status == 0 ? result?.stdout : nil
        })
        let answers = try #require(locator.current())
        #expect(answers.executables == ["sh": "/bin/sh"])
        #expect(!answers.pythonOutput.contains("sh\t"))
        #expect(!answers.pythonOutput.contains("banner"))
        #expect(PythonLocator.candidates(shellOutput: answers.pythonOutput).allSatisfy { $0.path.hasPrefix("/") })
    }

    /// A name the locator does not ask about is looked up on its own, and not kept.
    @Test func anotherNameIsLookedUpOnItsOwn() {
        let asked = Mutex<[String]>([])
        let locator = LoginShellLocator(names: ["claude"], shell: { query in
            asked.withLock { $0.append(query) }
            return "node\t/bin/sh\n"
        })
        #expect(locator.locate("node") == "/bin/sh")
        #expect(asked.withLock { $0 } == [LoginShell.locateQuery(["node"])])
    }
}

/// A login shell that prints a canned answer after a pause, and counts how often it was started.
private final class CountingShell: Sendable {
    private let output: Mutex<String?>
    private let started = Mutex(0)
    private let delay: TimeInterval

    init(_ output: String?, delay: TimeInterval = 0.2) {
        self.output = Mutex(output)
        self.delay = delay
    }

    var spawns: Int { started.withLock { $0 } }

    func answer(_ output: String?) { self.output.withLock { $0 = output } }

    func run(_ query: String) -> String? {
        started.withLock { $0 += 1 }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return output.withLock { $0 }
    }
}
