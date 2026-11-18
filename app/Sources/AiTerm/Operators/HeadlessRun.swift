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
