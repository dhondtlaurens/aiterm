import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct WorkerGuardCLITests {
    @Test func hookAndArgvModesDenyForceAndNoVerifyBeforeAnyHostRead() async throws {
        let folder = try ScratchFolder.make("aiterm-worker-cli-")
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = folder.appendingPathComponent("scope.json")
        let scope = WorkerGuard.Scope(task: UUID(), worktree: folder.path, branch: "feat/pay-1", remote: "https://git.example/shop/web", allowsPush: true)
        try JSONEncoder().encode(scope).write(to: config)
        let dependencies = WorkerGuardCLI.Dependencies(git: .hermetic(), fence: { _ in
            Issue.record("A local denial must not read the host."); throw WorkerGuard.GuardFailure("Unexpected host read.")
        })
        let hook = Data(#"{"tool_name":"Bash","tool_input":{"command":"git push --no-verify"}}"#.utf8)
        let answer = await WorkerGuardCLI.run(["hook", config.path], input: hook, dependencies: dependencies)
        #expect(answer.status == 0)
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(answer.output.utf8))
        #expect(json["hookSpecificOutput"]?["permissionDecision"] == "deny")
        let direct = await WorkerGuardCLI.run(["argv", config.path, "git", "push", "--force-with-lease"], dependencies: dependencies)
        #expect(direct.status != 0 && direct.error.contains("force"))
    }
    @Test func aConfiguredAliasCannotHideThePushOptionsPassedToIt() async throws {
        let branch = "feat/pay-1", git = GitRunner.hermetic()
        let repo = try await BackgroundWork.run {
            let repo = try GitFixture.withOrigin(branch: branch)
            try git.run(["config", "alias.publish", "push"], in: repo.path)
            return repo
        }
        let folder = try ScratchFolder.make("aiterm-worker-alias-")
        let config = folder.appendingPathComponent("scope.json")
        let scope = WorkerGuard.Scope(task: UUID(), worktree: repo.path, branch: branch, remote: repo.origin, allowsPush: true)
        try JSONEncoder().encode(scope).write(to: config)
        let result = await WorkerGuardCLI.run(["argv", config.path, "git", "-C", repo.path, "publish", "--no-verify"],
            dependencies: .init(git: git, fence: { _ in .init(defaultBranch: "main", protection: .unprotected) }))
        #expect(result.status != 0)
    }

    @Test func graphqlQueriesReadFromFilesStillRefuseMerge() async throws {
        let folder = try ScratchFolder.make("aiterm-worker-graphql-")
        let config = folder.appendingPathComponent("scope.json"), query = folder.appendingPathComponent("query.graphql")
        let scope = WorkerGuard.Scope(task: UUID(), worktree: folder.path, branch: "feat/pay-1", remote: "https://git.example/shop/web", allowsPush: true)
        try JSONEncoder().encode(scope).write(to: config)
        try "mutation { mergePullRequest(input: {}) { clientMutationId } }".write(to: query, atomically: true, encoding: .utf8)
        let result = await WorkerGuardCLI.run(["argv", config.path, "gh", "api", "graphql", "-F", "query=@" + query.path],
            dependencies: .init(git: .hermetic(), fence: { _ in .init(defaultBranch: "main", protection: .unprotected) }))
        #expect(result.status != 0)
    }

    @Test func scratchRepositoryChecksObserveHostAuthorityAgainAfterItsRead() async throws {
        let branch = "feat/pay-1", git = GitRunner.hermetic()
        let repo = try await BackgroundWork.run { try GitFixture.withOrigin(branch: branch) }
        let folder = try ScratchFolder.make("aiterm-worker-cli-")
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = folder.appendingPathComponent("scope.json")
        let scope = WorkerGuard.Scope(task: UUID(), worktree: repo.path, branch: branch, remote: repo.origin, allowsPush: true)
        try JSONEncoder().encode(scope).write(to: config)
        let refs = Data("refs/heads/\(branch) \(repo.sha) refs/heads/\(branch) \(String(repeating: "0", count: 40))\n".utf8)
        let allowed = await WorkerGuardCLI.run(["push", config.path, "origin", repo.origin], input: refs,
            dependencies: .init(git: git, fence: { _ in .init(defaultBranch: "main", protection: .unprotected) }))
        #expect(allowed.status == 0)
        let moved = await WorkerGuardCLI.run(["push", config.path, "origin", repo.origin], input: refs,
            dependencies: .init(git: git, fence: { _ in
                try await BackgroundWork.run { try git.run(["commit", "--allow-empty", "-m", "Later work"], in: repo.path) }
                return .init(defaultBranch: "main", protection: .unprotected)
            }))
        #expect(moved.status != 0, "A push must still be the current head after the host read.")
        let changed = await WorkerGuardCLI.run(["push", config.path, "origin", repo.origin], input: refs,
            dependencies: .init(git: git, fence: { _ in
                var next = scope; next.allowsPush = false
                try JSONEncoder().encode(next).write(to: config, options: .atomic)
                return .init(defaultBranch: "main", protection: .unprotected)
            }))
        #expect(changed.status != 0)
        #expect(changed.error.contains("changed"))
    }
}
