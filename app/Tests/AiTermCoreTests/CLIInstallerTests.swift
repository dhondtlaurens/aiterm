import Foundation
import Testing
@testable import AiTermCore

@Suite struct CLIInstallerTests {
    @Test func eachHarnessInstallsThroughItsVendorsOwnScript() {
        #expect(CLIInstaller.command(for: .claude) == "curl -fsSL https://claude.ai/install.sh | bash")
        #expect(CLIInstaller.command(for: .codex) == "curl -fsSL https://chatgpt.com/codex/install.sh | sh")
        #expect(CLIInstaller.command(for: .pi) == "curl -fsSL https://pi.dev/install.sh | sh")
    }

    @Test func grokUsesXAIsInstaller() {
        #expect(CLIInstaller.command(for: .grok) == "curl -fsSL https://x.ai/cli/install.sh | bash")
    }

    /// A login shell, so the installer sees the `PATH` the task window will have: Codex's decides
    /// from `$PATH` whether to add `~/.local/bin` to a profile. Nothing can answer a prompt.
    @Test func theInstallerRunsInALoginShellWithPromptsOff() throws {
        let calls = Calls()
        let runner = HarnessCommandRunner(locate: { _ in nil }, run: { executable, arguments, environment, timeout in
            calls.record(executable, arguments, environment, timeout)
            return ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false)
        })

        try CLIInstaller.install(.codex, runner: runner)

        let call = try #require(calls.all.first)
        #expect(calls.all.count == 1)
        #expect(call.executable == "/bin/zsh")
        #expect(call.arguments == ["-lic", "set -o pipefail; " + CLIInstaller.command(for: .codex)])
        #expect(call.environment["CODEX_NON_INTERACTIVE"] == "1")
        #expect(call.timeout >= 300)
    }

    /// The card has one line for the reason: the installer's last word on it, without its colours.
    @Test func aFailedInstallReportsTheInstallersLastLine() {
        let piWithoutNode = ProcessOutput(
            status: 1, stdout: "Checking Node.js…\nNo terminal detected; install Node.js 22.19.0 or newer and npm, then run this installer again.\n\n",
            stderr: "", timedOut: false)
        #expect(CLIInstaller.failure(.pi, piWithoutNode)
                == .failed(.pi, "No terminal detected; install Node.js 22.19.0 or newer and npm, then run this installer again."))

        let coloured = ProcessOutput(status: 1, stdout: "Downloading…\n",
                                     stderr: "\u{1B}[31mChecksum verification failed\u{1B}[0m\n", timedOut: false)
        #expect(CLIInstaller.failure(.claude, coloured) == .failed(.claude, "Checksum verification failed"))

        let silent = ProcessOutput(status: 6, stdout: "", stderr: "", timedOut: false)
        #expect(CLIInstaller.failure(.codex, silent) == .failed(.codex, "The installer exited with status 6."))

        let slow = ProcessOutput(status: 15, stdout: "Downloading…", stderr: "", timedOut: true)
        #expect(CLIInstaller.failure(.pi, slow) == .timedOut(.pi))
        #expect(CLIInstaller.failure(.pi, ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false)) == nil)
    }

    @Test func missingCLIIsInstalledThenItsDriver() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installed = Calls()
        let runner = HarnessCommandRunner(locate: { _ in installed.all.isEmpty ? nil : "/usr/bin/true" },
                                          run: { executable, arguments, environment, timeout in
            if executable == "/bin/zsh" { installed.record(executable, arguments, environment, timeout) }
            return ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false)
        })
        let service = HarnessService(home: home, daemonPort: 47821, runner: runner, resources: resources)

        #expect(await service.probe(.codex).health == .unavailable)
        let snapshot = try await service.install(.codex)

        #expect(installed.all.map(\.arguments) == [["-lic", "set -o pipefail; " + CLIInstaller.command(for: .codex)]])
        #expect(snapshot.health != .unavailable)
        #expect(snapshot.integrationState == .current)
    }

    @Test func aPresentCLIIsNeverReinstalled() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let shells = Calls()
        let runner = HarnessCommandRunner(locate: { _ in "/usr/bin/true" }, run: { executable, arguments, environment, timeout in
            if executable == "/bin/zsh" { shells.record(executable, arguments, environment, timeout) }
            return ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false)
        })
        let service = HarnessService(home: home, daemonPort: 47821, runner: runner, resources: resources)

        _ = try await service.install(.codex)

        #expect(shells.all.isEmpty)
    }

    @Test func aFailedInstallerWritesNoDriver() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = HarnessCommandRunner(locate: { _ in nil }, run: { _, _, _, _ in
            ProcessOutput(status: 1, stdout: "", stderr: "curl: (6) Could not resolve host: chatgpt.com\n", timedOut: false)
        })
        let service = HarnessService(home: home, daemonPort: 47821, runner: runner, resources: resources)

        await #expect(throws: CLIInstallError.failed(.codex, "curl: (6) Could not resolve host: chatgpt.com")) {
            _ = try await service.install(.codex)
        }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path))
    }

    /// `curl … | sh` exits with `sh`'s status, and `sh` given nothing to run exits 0: a download
    /// that failed read as "installed, but not on your PATH". The runner here answers as zsh
    /// would — curl's failure only reaches the exit status under `pipefail`.
    @Test func aFailedDownloadIsReportedAsCurlsError() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = HarnessCommandRunner(locate: { _ in nil }, run: { _, arguments, _, _ in
            let pipefail = arguments.last?.hasPrefix("set -o pipefail; ") == true
            return ProcessOutput(status: pipefail ? 6 : 0, stdout: "",
                                 stderr: "curl: (6) Could not resolve host: claude.ai\n", timedOut: false)
        })
        let service = HarnessService(home: home, daemonPort: 47821, runner: runner, resources: resources)

        await #expect(throws: CLIInstallError.failed(.claude, "curl: (6) Could not resolve host: claude.ai")) {
            _ = try await service.install(.claude)
        }
    }

    /// What `pipefail` does to the installer's pipeline, in the zsh it runs in.
    @Test func pipefailCarriesTheDownloadsStatus() throws {
        let failed = try ProcessRunner.run(URL(fileURLWithPath: "/bin/zsh"), ["-fc", "set -o pipefail; (exit 6) | sh"], timeout: 5)
        #expect(failed.status == 6)
    }

    /// The installer can finish without the CLI being where a task window's shell will look — the
    /// Claude installer, say, when `~/.local/bin` is on no profile's `PATH`.
    @Test func anInstalledCLIOffThePathSaysSo() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = HarnessCommandRunner(locate: { _ in nil }, run: { _, _, _, _ in
            ProcessOutput(status: 0, stdout: "", stderr: "", timedOut: false)
        })
        let service = HarnessService(home: home, daemonPort: 47821, runner: runner, resources: resources)

        await #expect(throws: CLIInstallError.notOnPath(.claude)) { _ = try await service.install(.claude) }
        #expect(CLIInstallError.notOnPath(.claude).errorDescription
                == "Claude Code installed, but `claude` isn’t on your login shell’s PATH.")
    }

    private let resources = HarnessResources(claudeShimPath: "/usr/bin/true", piExtensionSource: nil,
                                             grokShimPath: nil, installationAllowed: true, unavailableReason: nil)

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-cli-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }
}

/// Unchecked because its stored `var`s are mutable: every access holds `lock`.
private final class Calls: @unchecked Sendable {
    struct Call { var executable: String; var arguments: [String]; var environment: [String: String]; var timeout: TimeInterval }
    private let lock = NSLock()
    private var calls: [Call] = []

    func record(_ executable: String, _ arguments: [String], _ environment: [String: String], _ timeout: TimeInterval) {
        lock.withLock { calls.append(Call(executable: executable, arguments: arguments, environment: environment, timeout: timeout)) }
    }

    var all: [Call] { lock.withLock { calls } }
}
