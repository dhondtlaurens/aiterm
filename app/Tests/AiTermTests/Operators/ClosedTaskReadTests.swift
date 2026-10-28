import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor @Suite struct ClosedTaskReadTests {
    @Test(arguments: [false, true]) func closedDiffUsesTheSavedBaseOrTheOldRecordsCommitPatch(old: Bool) async throws {
        let git = GitRunner.hermetic()
        let path = try GitFixture.makeRepo(prefix: "closed-diff", git: git)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let base = try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        for file in ["first", "second"] {
            try file.write(toFile: path + "/" + file, atomically: true, encoding: .utf8)
            try git.run(["add", file], in: path)
            try git.run(["commit", "-m", file], in: path)
        }
        let sha = try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        let project = OperatorServiceFixtures.project(path: path)
        var run = OperatorServiceFixtures.run(projects: [project], state: .complete, taskSettings: TaskSettings(review: nil, end: .commit))
        var record = FinishedTaskRecord(task: UUID(), key: "A", title: "Two commits", ticket: nil, project: project.id,
                                        agent: .codex, model: "m", reasoning: nil, end: .commit, state: .accepted,
                                        acceptedSHA: sha, branch: "gone", mergeRequestURL: nil, mergedSHA: nil,
                                        result: "accepted", branchDeleted: false, at: Date())
        record.diffBaseSHA = old ? nil : base
        run.finished = [record]
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]), git: git)
        let result = try await world.controller.tools.readTask(ToolCall(tool: "read_task", arguments: ["task": "A", "what": "diff"]), in: run)
        let encoded = String(data: try JSONEncoder().encode(result), encoding: .utf8)!
        #expect(encoded.contains("second"))
        #expect(encoded.contains("first") == !old)
        for what in ["lastMessage", "prompt", "review"] {
            let answer = try await world.controller.tools.readTask(ToolCall(tool: "read_task", arguments: ["task": "A", "what": .string(what)]), in: run)
            #expect(String(data: try JSONEncoder().encode(answer), encoding: .utf8)!.contains("closed"))
        }
        // A missing saved endpoint is a tool refusal, not a raw git failure.
        run.finished[0].acceptedSHA = String(repeating: "0", count: 40)
        do {
            _ = try await world.controller.tools.readTask(ToolCall(tool: "read_task", arguments: ["task": "A", "what": "diff"]), in: run)
            Issue.record("Expected a refusal for an unreadable accepted commit")
        } catch is ToolRefusal {
        } catch { Issue.record("Expected ToolRefusal, got \(error)") }
    }

    @Test func aClosedDiffReadsFromWhereItsBranchLeftABaseThatMovedOn() async throws {
        let git = GitRunner.hermetic()
        let path = try GitFixture.makeRepo(prefix: "closed-diff-moved", git: git)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let start = try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        try "elsewhere".write(toFile: path + "/elsewhere", atomically: true, encoding: .utf8)
        try git.run(["add", "elsewhere"], in: path)
        try git.run(["commit", "-m", "elsewhere"], in: path)
        let moved = try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        try git.run(["checkout", "-q", "-b", "task", start], in: path)
        try "work".write(toFile: path + "/work", atomically: true, encoding: .utf8)
        try git.run(["add", "work"], in: path)
        try git.run(["commit", "-m", "work"], in: path)
        let sha = try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        let project = OperatorServiceFixtures.project(path: path)
        var run = OperatorServiceFixtures.run(projects: [project], state: .complete, taskSettings: TaskSettings(review: nil, end: .commit))
        var record = FinishedTaskRecord(task: UUID(), key: "A", title: "Work", ticket: nil, project: project.id,
                                        agent: .codex, model: "m", reasoning: nil, end: .commit, state: .accepted,
                                        acceptedSHA: sha, branch: "task", mergeRequestURL: nil, mergedSHA: nil,
                                        result: "accepted", branchDeleted: false, at: Date())
        record.diffBaseSHA = moved
        run.finished = [record]
        let world = try OperatorWorld(OperatorServiceFixtures.state(projects: [project], runs: [run]), git: git)
        let result = try await world.controller.tools.readTask(ToolCall(tool: "read_task", arguments: ["task": "A", "what": "diff"]), in: run)
        let encoded = String(data: try JSONEncoder().encode(result), encoding: .utf8)!
        #expect(encoded.contains("work"))
        #expect(!encoded.contains("elsewhere"))
    }
}
