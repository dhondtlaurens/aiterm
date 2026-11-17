import Foundation
import Testing
import Synchronization
@testable import AiTermCore
@testable import AiTerm

/// The Oracle never blocks the act: one that is missing, fails or runs out of time
/// lets it proceed, unanswered, with the reason.
@Suite struct OracleRunnerTests {
    let opinion = OracleSetting(isOn: true, agent: .claude, model: "m", reasoning: nil)
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())

    /// What the fake run was asked to run: the executable, the folder, then the arguments.
    final class Seen: Sendable { let words = Mutex<[String]>([]) }

    func runner(_ output: ProcessOutput, seen: Seen? = nil) -> OracleRunner {
        OracleRunner(locate: { "/opt/bin/\($0)" }, run: { executable, arguments, _, directory, _ in
            seen?.words.withLock { $0 = [executable, directory] + arguments }
            return output
        })
    }

    @Test func aCritiqueComesBackFromTheOracleInTheOperatorFolder() async {
        let seen = Seen()
        let verdict = await runner(ProcessOutput(status: 0, stdout: #"{"result":"Split A."}"#, stderr: "", timedOut: false), seen: seen)
            .ask(opinion, prompt: "P", folder: folder, projects: [])
        #expect(verdict == .critique("Split A."))
        #expect(seen.words.withLock { Array($0.prefix(4)) } == ["/opt/bin/claude", folder.path, "-p", "P"])
    }

    @Test func aRunOutOfTimeOrWithoutAnAnswerIsUnanswered() async {
        let late = await runner(ProcessOutput(status: 143, stdout: "", stderr: "", timedOut: true)).ask(opinion, prompt: "P", folder: folder, projects: [])
        #expect(late == .unanswered("The Oracle didn’t answer within 3 minutes."))
        let silent = await runner(ProcessOutput(status: 2, stdout: "", stderr: "boom", timedOut: false)).ask(opinion, prompt: "P", folder: folder, projects: [])
        #expect(silent == .unanswered("The Oracle gave no critique (exit 2)."))
    }

    @Test func aMissingCLIIsUnanswered() async {
        let missing = OracleRunner(locate: { _ in nil }, run: { _, _, _, _, _ in Issue.record("nothing runs"); throw CancellationError() })
        #expect(await missing.ask(opinion, prompt: "P", folder: folder, projects: []) == .unanswered("claude isn’t installed."))
    }
}
