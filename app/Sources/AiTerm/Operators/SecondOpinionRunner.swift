import Foundation
import AiTermCore

/// Runs the second opinion and says what came of it. It never blocks the act (spec §4.4): a CLI that is
/// missing, a run that fails, says nothing or outlasts `timeout` is `unchallenged`, with the reason the
/// overview shows. An agent review (`review`) runs the same way, headless and read-only, in a task's worktree.
struct SecondOpinionRunner: Sendable {
    enum Verdict: Equatable, Sendable { case critique(String), unchallenged(String) }
    /// What an agent review came to: its findings, or why there are none.
    enum Review: Equatable, Sendable { case findings(String), failed(String) }
    typealias Run = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String], _ directory: String,
                               _ timeout: Duration) async throws -> ProcessOutput

    var locate: @Sendable (String) -> String?
    var run: Run
    var timeout: Duration = .seconds(OperatorTiming.challengeTimeout)

    /// The app's: the CLIs where the launch's probe found them, run as a fix's agent is.
    static let live = SecondOpinionRunner(locate: { HarnessCommandRunner.live.locate($0) },
                                          run: { try await AgentProcess.run($0, $1, environment: $2, in: $3, timeout: $4) })
    /// No second opinion at all: every challenged act proceeds unchallenged. What a test's ports start with.
    static let unavailable = SecondOpinionRunner(locate: { _ in nil }, run: { _, _, _, _, _ in throw CancellationError() })

    func challenge(_ opinion: OracleSetting, prompt: String, runFolder: URL, projects: [String]) async -> Verdict {
        let answerFile = runFolder.appendingPathComponent("challenge-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: answerFile) }
        guard let invocation = ChallengeLaunch.invocation(opinion, prompt: prompt, runFolder: runFolder.path, projects: projects,
                                                          answerFile: answerFile) else {
            return .unchallenged("\(opinion.agent.harness.displayName) can’t give a second opinion.")
        }
        switch await perform(invocation, in: runFolder.path, timeout: timeout) {
        case .failure(let why): return .unchallenged(why.text(of: "The second opinion"))
        case .success(let output):
            guard let critique = ChallengeLaunch.critique(opinion.agent, output: output, answerFile: invocation.answerFile) else {
                return .unchallenged("The second opinion gave no critique (exit \(output.status)).")
            }
            return .critique(critique)
        }
    }

    /// An agent review by `agent` on `model`, read-only in `worktree`, its answer file in `folder`, which is made
    /// if it is missing: the findings, or why there are none.
    func review(agent: AgentKind, model: String, reasoning: String?, prompt: String, worktree: String, folder: URL,
                timeout: Duration) async -> Review {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let answerFile = folder.appendingPathComponent("review-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: answerFile) }
        guard let invocation = AgentReview.invocation(agent: agent, model: model, reasoning: reasoning, prompt: prompt, worktree: worktree,
                                                      answerFile: answerFile) else {
            return .failed("\(agent.harness.displayName) can’t review headless.")
        }
        switch await perform(invocation, in: worktree, timeout: timeout) {
        case .failure(let why): return .failed(why.text(of: "The review"))
        case .success(let output):
            guard let findings = AgentReview.findings(agent, output: output, answerFile: invocation.answerFile) else {
                return .failed("The review gave no findings (exit \(output.status)).")
            }
            return .findings(findings)
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

    private func perform(_ invocation: FixerInvocation, in directory: String, timeout: Duration) async -> Result<ProcessOutput, NoOutput> {
        let name = invocation.executable, locate = self.locate
        guard let executable = await BackgroundWork.run({ locate(name) }) else { return .failure(.missing(name)) }
        // As a fix's agent: a CLI installed by npm needs its own bin on the PATH launchd gives an app.
        var environment = invocation.environment
        let bin = (executable as NSString).deletingLastPathComponent
        environment["PATH"] = [bin, ProcessRunner.inheritedEnvironment["PATH"]].compactMap { $0 }.joined(separator: ":")
        let output: ProcessOutput
        do { output = try await run(executable, invocation.arguments, environment, directory, timeout) }
        catch { return .failure(.failed(error.localizedDescription)) }
        if output.timedOut { return .failure(.timedOut(timeout)) }
        return .success(output)
    }
}
