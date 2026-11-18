import Foundation
import AiTermCore

/// Runs the Oracle and returns its critique, or `unanswered` with a reason when its CLI is missing, fails,
/// says nothing or outlasts `timeout`. `TabOpener` owns interactive review tabs.
struct OracleRunner: Sendable {
    enum Verdict: Equatable, Sendable { case critique(String), unanswered(String) }

    typealias Run = HeadlessRun.Run

    var locate: @Sendable (String) -> String?
    var run: Run
    var timeout: Duration = .seconds(OperatorTiming.oracleTimeout)

    /// The app's: the CLIs where the launch probe found them, in a process group with a timeout.
    static let live = OracleRunner(locate: HeadlessRun.live.locate, run: HeadlessRun.live.run)
    /// The Oracle is unavailable; each request returns unanswered. What a test's ports start with.
    static let unavailable = OracleRunner(locate: { _ in nil }, run: { _, _, _, _, _ in throw CancellationError() })

    func ask(_ opinion: OracleSetting, prompt: String, folder: URL, projects: [String]) async -> Verdict {
        let answerFile = folder.appendingPathComponent("oracle-\(UUID().uuidString).txt").path
        defer { try? FileManager.default.removeItem(atPath: answerFile) }
        let invocation = OracleLaunch.invocation(opinion, prompt: prompt, folder: folder.path, projects: projects,
                                                    answerFile: answerFile)
        switch await HeadlessRun(locate: locate, run: run).perform(invocation, in: folder.path, timeout: timeout) {
        case .failure(let why): return .unanswered(why.text(of: "The Oracle"))
        case .success(let output):
            guard let critique = OracleLaunch.critique(opinion.agent, output: output, answerFile: invocation.answerFile) else {
                return .unanswered("The Oracle gave no critique (exit \(output.status)).")
            }
            return .critique(critique)
        }
    }
}
