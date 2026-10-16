import Foundation
import Testing
import Synchronization
@testable import AiTermCore
@testable import AiTerm

/// The second opinion never blocks the act (spec §4.4): one that is missing, fails or runs out of time
/// lets it proceed, unchallenged, with the reason.
@Suite struct SecondOpinionRunnerTests {
    let opinion = SecondOpinion(level: .healthyDoubt, agent: .claude, model: "m", effort: nil)
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())

    /// What the fake run was asked to run: the executable, the folder, then the arguments.
    final class Seen: Sendable { let words = Mutex<[String]>([]) }

    func runner(_ output: ProcessOutput, seen: Seen? = nil) -> SecondOpinionRunner {
        SecondOpinionRunner(locate: { "/opt/bin/\($0)" }, run: { executable, arguments, _, directory, _ in
            seen?.words.withLock { $0 = [executable, directory] + arguments }
            return output
        })
    }

    @Test func aCritiqueComesBackFromTheRunInTheRunFolder() async {
        let seen = Seen()
        let verdict = await runner(ProcessOutput(status: 0, stdout: #"{"result":"Split A."}"#, stderr: "", timedOut: false), seen: seen)
            .challenge(opinion, prompt: "P", runFolder: folder, projects: [])
        #expect(verdict == .critique("Split A."))
        #expect(seen.words.withLock { Array($0.prefix(4)) } == ["/opt/bin/claude", folder.path, "-p", "P"])
    }

    @Test func aRunOutOfTimeOrWithoutAnAnswerIsUnchallenged() async {
        let late = await runner(ProcessOutput(status: 143, stdout: "", stderr: "", timedOut: true)).challenge(opinion, prompt: "P", runFolder: folder, projects: [])
        #expect(late == .unchallenged("The second opinion didn’t answer within 3 minutes."))
        let silent = await runner(ProcessOutput(status: 2, stdout: "", stderr: "boom", timedOut: false)).challenge(opinion, prompt: "P", runFolder: folder, projects: [])
        #expect(silent == .unchallenged("The second opinion gave no critique (exit 2)."))
    }

    @Test func aMissingCLIIsUnchallenged() async {
        let missing = SecondOpinionRunner(locate: { _ in nil }, run: { _, _, _, _, _ in Issue.record("nothing runs"); throw CancellationError() })
        #expect(await missing.challenge(opinion, prompt: "P", runFolder: folder, projects: []) == .unchallenged("claude isn’t installed."))
    }
}
