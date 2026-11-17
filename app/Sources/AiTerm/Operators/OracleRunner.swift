import Foundation
import AiTermCore

/// Runs the Oracle and returns its critique, or `unanswered` with a reason when its CLI is missing, fails,
/// says nothing or outlasts `timeout`. `TabOpener` owns interactive review tabs.
struct OracleRunner: Sendable {
    enum Verdict: Equatable, Sendable { case critique(String), unanswered(String) }

    typealias Run = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String], _ directory: String,
                               _ timeout: Duration) async throws -> ProcessOutput

    var locate: @Sendable (String) -> String?
    var run: Run
    var timeout: Duration = .seconds(OperatorTiming.oracleTimeout)

    /// The app's: the CLIs where the launch probe found them, in a process group with a timeout.
    static let live = OracleRunner(locate: { HarnessCommandRunner.live.locate($0) },
                                          run: { try await AgentProcess.run($0, $1, environment: $2, in: $3, timeout: $4) })
    /// The Oracle is unavailable; each request returns unanswered. What a test's ports start with.
    static let unavailable = OracleRunner(locate: { _ in nil }, run: { _, _, _, _, _ in throw CancellationError() })

    func ask(_ opinion: OracleSetting, prompt: String, folder: URL, projects: [String]) async -> Verdict {
        let answerFile = folder.appendingPathComponent("oracle-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: answerFile) }
        let invocation = OracleLaunch.invocation(opinion, prompt: prompt, folder: folder.path, projects: projects,
                                                    answerFile: answerFile)
        switch await perform(invocation, in: folder.path, timeout: timeout) {
        case .failure(let why): return .unanswered(why.text(of: "The Oracle"))
        case .success(let output):
            guard let critique = OracleLaunch.critique(opinion.agent, output: output, answerFile: invocation.answerFile) else {
                return .unanswered("The Oracle gave no critique (exit \(output.status)).")
            }
            return .critique(critique)
        }
    }

    /// Why a run gave no output to read.
    private enum NoOutput: Error {
        case missing(String), failed(String), timedOut(Duration)
        func text(of what: String) -> String {
            switch self {
            case .missing(let name): return "\(name) isn’t installed."
            case .failed(let why): return "\(what) couldn’t run: \(why)"
            case .timedOut(let limit): return "\(what) didn’t answer within \(limit.components.seconds / 60) minutes."
            }
        }
    }

    private func perform(_ invocation: HeadlessInvocation, in directory: String, timeout: Duration) async -> Result<ProcessOutput, NoOutput> {
        let name = invocation.executable, locate = self.locate
        guard let executable = await BackgroundWork.run({ locate(name) }) else { return .failure(.missing(name)) }
        // A CLI installed by npm needs its own bin on the PATH launchd gives an app.
        let environment = ProcessRunner.environment(runningCLI: executable, overrides: invocation.environment)
        let output: ProcessOutput
        do { output = try await run(executable, invocation.arguments, environment, directory, timeout) }
        catch { return .failure(.failed(error.localizedDescription)) }
        if output.timedOut { return .failure(.timedOut(timeout)) }
        return .success(output)
    }
}
