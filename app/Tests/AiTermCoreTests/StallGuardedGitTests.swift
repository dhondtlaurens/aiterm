import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The guard that gives up on a project once git has timed out in it.
struct StallGuardedGitTests {
    /// Times out in the folders it is told to, runs nothing otherwise, and counts what it was asked.
    private final class Stub: GitRunning {
        private let state = Mutex((hung: Set<String>(), asked: [String]()))
        var asked: [String] { state.withLock { $0.asked } }
        func hang(_ folder: String, _ on: Bool) { state.withLock { if on { $0.hung.insert(folder) } else { $0.hung.remove(folder) } } }

        func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
            let hangs = state.withLock { $0.asked.append(dir); return $0.hung.contains(dir) }
            if hangs { throw GitError(args: args, code: 15, stderr: "git status timed out after \(Int(timeout)) s") }
            return "ok"
        }
    }

    private func project(_ path: String) -> Project {
        Project(id: UUID(), name: path, path: path, provider: .git, remoteUrl: nil, addedAt: Date(), collapsed: false)
    }

    private func task(_ project: Project, _ path: String) -> TaskItem {
        TaskItem(id: UUID(), projectId: project.id, title: "t", branch: "b", worktreePath: path, baseBranch: "main",
                 jira: nil, agent: .claude, model: "m", reasoning: nil, firstPrompt: nil, appendTicket: false,
                 createdAt: Date(), windowId: nil)
    }

    @Test func aTimeoutStallsTheWholeProjectAndNoOther() {
        let clock = TestClock(), stub = Stub()
        let guarded = StallGuardedGit(stub, now: { clock.now })
        let one = project("/mnt/one"), two = project("/work/two")
        let imported = task(one, "/elsewhere/imported")
        guarded.scope(projects: [one, two], tasks: [imported])
        stub.hang("/mnt/one", true)
        #expect(throws: GitError.self) { try guarded.run(["status"], in: "/mnt/one") }
        #expect(stub.asked == ["/mnt/one"])
        for dir in ["/mnt/one", "/mnt/one/.worktrees/a", "/elsewhere/imported", "/elsewhere/imported/src"] {
            let error = #expect(throws: GitError.self) { try guarded.run(["status"], in: dir) }
            #expect(error?.timedOut == true, "a skipped command reads as a timeout to the resolvers: \(dir)")
        }
        #expect(stub.asked == ["/mnt/one"], "none of them started git")
        #expect((try? guarded.run(["status"], in: "/work/two")) == "ok")
        #expect((try? guarded.run(["status"], in: "/mnt/oneother")) == "ok", "a folder that only shares a prefix of the name is not inside")
    }

    @Test func theProjectIsAskedAgainOnceTheBackoffIsOver() {
        let clock = TestClock(), stub = Stub()
        let guarded = StallGuardedGit(stub, now: { clock.now })
        guarded.scope(projects: [project("/mnt/one")], tasks: [])
        stub.hang("/mnt/one", true)
        _ = try? guarded.run(["status"], in: "/mnt/one")
        clock.advance(by: TimedOut.backoff - 1)
        _ = try? guarded.run(["status"], in: "/mnt/one")
        #expect(stub.asked.count == 1)
        clock.advance(by: 1)
        stub.hang("/mnt/one", false)
        #expect((try? guarded.run(["status"], in: "/mnt/one")) == "ok")
        #expect((try? guarded.run(["status"], in: "/mnt/one/sub")) == "ok", "and the stall is over for good")
    }

    /// A refusal is an answer, not a stall.
    @Test func aFailureThatIsNotATimeoutStallsNothing() {
        struct Refuses: GitRunning {
            func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
                throw GitError(args: args, code: 128, stderr: "fatal: not a git repository")
            }
        }
        let counting = RecordingGitRunner(forwardingTo: Refuses())
        let guarded = StallGuardedGit(counting)
        _ = try? guarded.run(["status"], in: "/x")
        _ = try? guarded.run(["status"], in: "/x")
        #expect(counting.calls.count == 2)
    }
}
