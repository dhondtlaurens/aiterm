import Foundation
import AiTermCore

/// One headless agent run, shared by the Oracle and the query writer: the CLI found where the launch probe found it,
/// run in a process group with a timeout, or why it gave no output to read.
struct HeadlessRun: Sendable {
    typealias Run = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String], _ directory: String,
                               _ timeout: Duration) async throws -> ProcessOutput

    var locate: @Sendable (String) -> String?
    var run: Run

    /// The app's.
    static let live = HeadlessRun(locate: { HarnessCommandRunner.live.locate($0) },
                                  run: { try await AgentProcess.run($0, $1, environment: $2, in: $3, timeout: $4) })
    /// A manual review validates the entire event stream. PipeDrain keeps draining after
    /// the disk budget is exceeded and reports the overflow before an answer is accepted.
    static func manualReview(agent: AgentKind, capture: FileHandle) -> Self {
        Self(locate: { name in
            // This helper already runs in the tab's shell environment. Starting a second
            // interactive login shell under its controlling terminal can block on job control.
            let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            for directory in directories where directory.hasPrefix("/") {
                let path = String(directory) + "/" + name
                if LoginShell.isExecutableFile(path) { return path }
            }
            return live.locate(name)
        }, run: { executable, arguments, environment, directory, timeout in
            var childEnvironment = environment
            if agent == .agy {
                let home = URL(fileURLWithPath: directory).deletingLastPathComponent().appendingPathComponent("agy-home")
                childEnvironment = try ManualReviewAgy.environment(in: home,
                    inheriting: ProcessRunner.inheritedEnvironment.merging(environment) { _, run in run })
                // Some versions silently ignore unknown fields in an agent definition. Only
                // launch on a version whose effective tool set and attached hook were exercised.
                let version = try await AgentProcess.run(executable, ["--version"], environment: childEnvironment,
                                                         in: directory, timeout: .seconds(10), outputLimit: 1024, inheritEnvironment: false)
                guard version.status == 0, !version.timedOut,
                      version.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == ManualReviewAgy.verifiedVersion else {
                    throw ManualReviewError("The trusted file reader requires Antigravity " + ManualReviewAgy.verifiedVersion + ".")
                }
            }
            return try await AgentProcess.run(executable, arguments, environment: childEnvironment, in: directory,
                                              timeout: timeout, outputLimit: 128 << 20, capture: capture, inheritEnvironment: agent != .agy)
        })
    }

    /// No CLI is found, so nothing runs. What a test's ports start with.
    static let unavailable = HeadlessRun(locate: { _ in nil }, run: { _, _, _, _, _ in throw CancellationError() })

    /// Why a run gave no output to read.
    enum NoOutput: Error, Equatable {
        case missing(String), failed(String), timedOut(Duration)
        func text(of what: String) -> String {
            switch self {
            case .missing(let name): return "\(name) isn’t installed."
            case .failed(let why): return "\(what) couldn’t run: \(why)"
            case .timedOut(let limit):
                let minutes = limit.components.seconds / 60
                return "\(what) didn’t answer within \(minutes <= 1 ? "a minute" : "\(minutes) minutes")."
            }
        }
    }

    func perform(_ invocation: HeadlessInvocation, in directory: String, timeout: Duration) async -> Result<ProcessOutput, NoOutput> {
        let name = invocation.executable, locate = self.locate
        guard let executable = await BackgroundWork.run({ locate(name) }) else { return .failure(.missing(name)) }
        // A CLI installed by npm needs its own bin on the PATH launchd gives an app.
        let environment = ProcessRunner.environment(runningCLI: executable, overrides: [:])
        let output: ProcessOutput
        do { output = try await run(executable, invocation.arguments, environment, directory, timeout) }
        catch { return .failure(.failed(error.localizedDescription)) }
        if output.timedOut { return .failure(.timedOut(timeout)) }
        return .success(output)
    }
}
