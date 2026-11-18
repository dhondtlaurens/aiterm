import Foundation
import Testing
import Synchronization
@testable import AiTermCore
@testable import AiTerm

/// The query writer with a fake run in place of Claude: one checked answer, one retry with the error, never more.
@Suite struct QueryWriterRunnerTests {
    /// Each run's folder and arguments, in order.
    final class Runs: Sendable {
        let seen = Mutex<[(folder: String, arguments: [String])]>([])
        var prompts: [String] { seen.withLock { $0.compactMap { run in run.arguments.firstIndex(of: "-p").map { run.arguments[$0 + 1] } } } }
    }

    static func answer(_ text: String) -> ProcessOutput {
        let json = try! JSONSerialization.data(withJSONObject: ["result": text])
        return ProcessOutput(status: 0, stdout: String(decoding: json, as: UTF8.self), stderr: "", timedOut: false)
    }

    func runner(_ outputs: [ProcessOutput], runs: Runs = Runs(),
                check: @escaping QueryWriterRunner.Checker = { _, _, _ in .passed }) -> QueryWriterRunner {
        let queue = Mutex(outputs)
        let headless = HeadlessRun(locate: { "/synthetic/bin/\($0)" }, run: { executable, arguments, _, directory, _ in
            #expect(executable == "/synthetic/bin/claude")
            runs.seen.withLock { $0.append((directory, arguments)) }
            return queue.withLock { $0.isEmpty ? QueryWriterRunnerTests.answer("") : $0.removeFirst() }
        })
        return QueryWriterRunner(headless: headless, check: check, model: "claude-opus-5-5", reasoning: "high")
    }

    @Test func aValidFirstAnswerIsTheQueryFromOneReadOnlyRunWithTheOperatorsModel() async throws {
        let runs = Runs()
        let outcome = await runner([Self.answer("```\nreviewer:@me review-state:unreviewed\n```")], runs: runs)
            .write(source: .gitLab, start: true, description: "Reviews asked of me", context: .init(gitLabUser: "alex"))
        #expect(outcome == .written("reviewer:@me review-state:unreviewed"))
        let run = try #require(runs.seen.withLock { $0.first })
        #expect(runs.seen.withLock { $0.count } == 1)
        #expect(run.folder.hasPrefix(FileManager.default.temporaryDirectory.path) && !FileManager.default.fileExists(atPath: run.folder),
                "a scratch folder, removed after")
        #expect(run.arguments.contains("--strict-mcp-config") && !run.arguments.contains("--add-dir"))
        #expect(run.arguments.suffix(4) == ["--model", "claude-opus-5-5", "--effort", "high"])
        #expect(runs.prompts.first?.hasSuffix("```\nReviews asked of me\n```") == true)
    }

    @Test func aRefusedFirstAnswerIsSentBackOnceWithItsError() async {
        let runs = Runs()
        let outcome = await runner([Self.answer("review-state:unreviewed"), Self.answer("reviewer:@me review-state:unreviewed")], runs: runs) {
            _, start, query in
            #expect(start)
            return query.hasPrefix("reviewer:@me") ? .passed : .refused("Name yourself in one role.")
        }.write(source: .gitLab, start: true, description: "Reviews", context: .init())
        #expect(outcome == .written("reviewer:@me review-state:unreviewed"))
        #expect(runs.prompts.count == 2)
        #expect(runs.prompts.last?.contains("It was (data):\n```\nreview-state:unreviewed\n```") == true)
        #expect(runs.prompts.last?.contains("```\nName yourself in one role.\n```") == true)
    }

    /// The second query is still returned, so the person can fix it, with the reason it fails.
    @Test func twoRefusedAnswersReturnTheSecondQueryAndItsError() async {
        let runs = Runs()
        let outcome = await runner([Self.answer("statuz = Done"), Self.answer("statuz = Closed"), Self.answer("never asked")], runs: runs) {
            _, _, query in .refused("Field 'statuz' does not exist (\(query)).")
        }.write(source: .jira, start: false, description: "When it's closed", context: .init())
        #expect(outcome == .failed("Claude’s query still fails: Field 'statuz' does not exist (statuz = Closed).", query: "statuz = Closed"))
        #expect(runs.prompts.count == 2, "one retry, never more")
    }

    /// An answer that is not one query counts as refused; a check that cannot run keeps the query without a retry.
    @Test func proseIsRetriedAndAnUncheckedQueryIsKept() async {
        let prose = await runner([Self.answer("Sure! Here it is:\nis:pr"), Self.answer("is:pr reviewed-by:@me")])
            .write(source: .gitHub, start: false, description: "When I've reviewed it", context: .init())
        #expect(prose == .written("is:pr reviewed-by:@me"))
        let runs = Runs()
        let unchecked = await runner([Self.answer("assignee = currentUser()")], runs: runs) { _, _, _ in .unchecked("Connect Jira in Settings to check it.") }
            .write(source: .jira, start: true, description: "Mine", context: .init())
        #expect(unchecked == .failed("Connect Jira in Settings to check it.", query: "assignee = currentUser()"))
        #expect(runs.prompts.count == 1)
    }

    @Test func aMissingCLIOrATimeoutSaysSoAndWritesNothing() async {
        let missing = QueryWriterRunner(headless: HeadlessRun(locate: { _ in nil }, run: { _, _, _, _, _ in
            Issue.record("nothing runs"); throw CancellationError()
        }), check: { _, _, _ in .passed }, model: "m", reasoning: nil)
        #expect(await missing.write(source: .jira, start: true, description: "Mine", context: .init())
                == .failed("Claude Code isn’t installed.", query: nil))
        let late = await runner([ProcessOutput(status: 143, stdout: "", stderr: "", timedOut: true)])
            .write(source: .jira, start: true, description: "Mine", context: .init())
        #expect(late == .failed("Claude didn’t answer within a minute.", query: nil))
    }
}
