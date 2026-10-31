import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

struct UnbornRepositoryTests {
    private let git = GitRunner.hermetic()

    private func unborn(_ branch: String = "main") throws -> String {
        let path = try GitFixture.folder("unborn-")
        try git.run(["init", "-b", branch, path], in: "/")
        return path
    }

    @Test func taskCreationExplainsAnUnbornBaseWithoutCommitting() throws {
        let path = try GitFixture.folder("unborn-")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try git.run(["init", "-b", "main", path], in: "/")
        let project = Project(id: UUID(), name: "New repository", path: path, provider: .git,
                              remoteUrl: nil, addedAt: Date(), collapsed: false)
        var draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "sonnet", reasoning: nil)
        draft.setTitle("First task")
        let error = try #require(#expect(throws: (any Error).self) {
            try TaskCreator.create(draft: draft, project: project, git: git)
        })
        #expect(error.localizedDescription.contains("no commits"))
        #expect(try Repository(path, git: git).commit("HEAD") == nil)
        #expect(try Repository(path, git: git).commit(draft.branch) == nil)
        #expect(!FileManager.default.fileExists(atPath: path + "/.worktrees/first-task"))
    }

    @Test(arguments: ["main", "master", "team/trunk"])
    func theUnbornBranchIsOfferedAsTheBase(branch: String) throws {
        let path = try unborn(branch)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let repository = Repository(path, git: git)
        #expect(try repository.detectDefaultBranch() == branch)
        #expect(repository.branches() == [branch])
        let error = #expect(throws: UnbornBranchError.self) {
            try repository.addTaskWorktree(slug: "first", branch: "feat/first", base: branch)
        }
        #expect(error?.branch == branch)
    }

    @Test func theCachedDefaultFollowsAnUnbornBranchRename() throws {
        let path = try unborn("master")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let resolver = DefaultBranchResolver(git: git)
        #expect(resolver.defaultBranch(for: path) == "master")
        try git.run(["symbolic-ref", "HEAD", "refs/heads/team/trunk"], in: path)
        #expect(resolver.defaultBranch(for: path) == "team/trunk")
    }

    @Test func initializationPreservesTheIndexAndEveryUncommittedFile() throws {
        let path = try unborn()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let repository = Repository(path, git: git)
        try "staged\n".write(toFile: path + "/staged", atomically: true, encoding: .utf8)
        try git.run(["add", "staged"], in: path)
        try "staged\nmodified\n".write(toFile: path + "/staged", atomically: true, encoding: .utf8)
        try "untracked\n".write(toFile: path + "/untracked", atomically: true, encoding: .utf8)
        let staged = try git.run(["ls-files", "--stage"], in: path)
        let status = try git.run(["status", "--porcelain"], in: path)

        try repository.initializeEmptyRepository(on: "main")

        #expect(try repository.commit("HEAD") != nil)
        #expect(try git.run(["ls-tree", "-r", "HEAD"], in: path).isEmpty)
        #expect(try git.run(["rev-list", "--count", "HEAD"], in: path) == "1")
        #expect(try git.run(["ls-files", "--stage"], in: path) == staged)
        #expect(try git.run(["status", "--porcelain"], in: path) == status)
        #expect(try String(contentsOfFile: path + "/staged", encoding: .utf8) == "staged\nmodified\n")
        #expect(try String(contentsOfFile: path + "/untracked", encoding: .utf8) == "untracked\n")

        let worktree = try repository.addTaskWorktree(slug: "first", branch: "feat/first", base: "main")
        #expect(try Repository(worktree, git: git).commit("HEAD") == repository.commit("main"))
        #expect(!FileManager.default.fileExists(atPath: worktree + "/staged"))
        #expect(try git.run(["ls-files", "--stage"], in: path) == staged)
    }

    @Test func initializationDoesNotRunHooksThatCouldIncludeFiles() throws {
        let path = try unborn()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let hook = path + "/.git/hooks/pre-commit"
        try "#!/bin/sh\necho changed > untracked\ngit add untracked\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        try "original\n".write(toFile: path + "/untracked", atomically: true, encoding: .utf8)
        try Repository(path, git: git).initializeEmptyRepository(on: "main")
        #expect(try git.run(["ls-tree", "-r", "HEAD"], in: path).isEmpty)
        #expect(try String(contentsOfFile: path + "/untracked", encoding: .utf8) == "original\n")
    }

    @Test func missingIdentityExplainsLocalConfigurationAndCanBeRetried() throws {
        let path = try unborn()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let environment = HermeticGit.environment.filter { !$0.key.hasPrefix("GIT_AUTHOR_") && !$0.key.hasPrefix("GIT_COMMITTER_") }
        let noIdentity = GitRunner(environment: environment, ignoringInherited: { $0.hasPrefix("GIT_") })
        let repository = Repository(path, git: noIdentity)
        try "keep\n".write(toFile: path + "/staged", atomically: true, encoding: .utf8)
        try git.run(["add", "staged"], in: path)
        let index = try git.run(["ls-files", "--stage"], in: path)
        let error = try #require(#expect(throws: RepositoryInitializationError.self) {
            try repository.initializeEmptyRepository(on: "main")
        })
        #expect(error.localizedDescription.contains("git config user.name"))
        #expect(error.localizedDescription.contains("git config user.email"))
        #expect(try repository.commit("HEAD") == nil)
        #expect(try git.run(["ls-files", "--stage"], in: path) == index)
        try git.run(["config", "user.name", "Test Person"], in: path)
        try git.run(["config", "user.email", "person@example.invalid"], in: path)
        try repository.initializeEmptyRepository(on: "main")
        #expect(try git.run(["show", "-s", "--format=%an <%ae>", "HEAD"], in: path) == "Test Person <person@example.invalid>")
        #expect(try git.run(["ls-tree", "-r", "HEAD"], in: path).isEmpty)
        #expect(try git.run(["ls-files", "--stage"], in: path) == index)
    }

    @Test func staleConsentNeverAddsAnotherCommitOrInitializesADifferentBranch() throws {
        let path = try unborn()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let repository = Repository(path, git: git)
        try git.run(["symbolic-ref", "HEAD", "refs/heads/other"], in: path)
        #expect(throws: RepositoryInitializationError.headChanged) { try repository.initializeEmptyRepository(on: "main") }
        #expect(try repository.commit("HEAD") == nil)
        try git.run(["symbolic-ref", "HEAD", "refs/heads/main"], in: path)
        try git.run(["commit", "--allow-empty", "-m", "Created elsewhere"], in: path)
        let head = try repository.commit("HEAD")
        try repository.initializeEmptyRepository(on: "main")
        #expect(try repository.commit("HEAD") == head)
        #expect(try git.run(["rev-list", "--count", "HEAD"], in: path) == "1")
        try git.run(["checkout", "--detach"], in: path)
        #expect(throws: RepositoryInitializationError.headChanged) { try repository.initializeEmptyRepository(on: "main") }
    }

    @Test(arguments: ["missing", "bad..ref", "", "--invalid"])
    func unrelatedMissingOrInvalidBasesKeepTheirGitError(base: String) throws {
        let path = try unborn()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let repository = Repository(path, git: git)
        #expect(throws: GitError.self) { try repository.addTaskWorktree(slug: "first", branch: "feat/first", base: base) }
        #expect(try repository.commit("HEAD") == nil)
        try repository.initializeEmptyRepository(on: "main")
        let head = try repository.commit("HEAD")
        #expect(throws: GitError.self) { try repository.addTaskWorktree(slug: "first", branch: "feat/first", base: base) }
        #expect(try repository.commit("HEAD") == head)
    }

    @Test func anUnbornCheckoutCanStillCreateFromAnExistingBase() throws {
        let path = try GitFixture.makeRepo(prefix: "orphan-", git: git)
        defer { try? FileManager.default.removeItem(atPath: path) }
        try git.run(["checkout", "--orphan", "new-root"], in: path)
        let repository = Repository(path, git: git)
        let worktree = try repository.addTaskWorktree(slug: "first", branch: "feat/first", base: "main")
        #expect(try repository.commit("HEAD") == nil)
        #expect(try Repository(worktree, git: git).commit("HEAD") == repository.commit("main"))
    }
}
