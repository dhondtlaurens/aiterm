import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite(.blocking) struct ManualReviewTests {
    @Test func snapshotReadsOnlyThePinnedTree() throws {
        let git = GitRunner.hermetic()
        let repo = try GitFixture.makeRepo(prefix: "review-input-")
        let scratch = try ScratchFolder.make("review-output-")
        defer { try? FileManager.default.removeItem(atPath: repo); try? FileManager.default.removeItem(at: scratch) }
        try git.run(["checkout", "-qb", "topic"], in: repo)
        let root = URL(fileURLWithPath: repo)
        try Data().write(to: root.appendingPathComponent("café.swift"))
        try Data("exact\r\n$Id$\n".utf8).write(to: root.appendingPathComponent("caller"))
        try Data("caller export-ignore ident\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        try FileManager.default.createSymbolicLink(atPath: repo + "/link", withDestinationPath: "/outside")
        try git.run(["add", "."], in: repo)
        try git.run(["commit", "-qm", "change"], in: repo)
        let head = try git.run(["rev-parse", "HEAD"], in: repo)
        try Data("dirty".utf8).write(to: root.appendingPathComponent("caller"))
        let refs = try git.run(["show-ref"], in: repo)
        let input = try Repository(repo, git: git).prepareManualReview(head: head, target: nil, in: scratch)
        #expect(input.base == (try git.run(["rev-parse", "main"], in: repo)))
        #expect(try Data(contentsOf: input.workspace.appendingPathComponent("source/caller")) == Data("exact\r\n$Id$\n".utf8))
        let paths = try String(contentsOf: input.workspace.appendingPathComponent("paths.txt"), encoding: .utf8)
        #expect(paths.split(separator: "\n").contains("café.swift"))
        let link = input.workspace.appendingPathComponent("source/link")
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(try String(contentsOf: link, encoding: .utf8) == "/outside")
        #expect(try String(contentsOf: input.workspace.appendingPathComponent("changes.patch"), encoding: .utf8).contains("+exact"))
        #expect(try git.run(["show-ref"], in: repo) == refs)
    }
}

extension ManualReviewTests {
    @Test func agyHomeSharesOnlyItsSignIn() throws {
        let root = try ScratchFolder.make("review-home-")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("person"), isolated = root.appendingPathComponent("isolated")
        let credentials = ".gemini/antigravity-cli/antigravity-oauth-token"
        let auth = home.appendingPathComponent(credentials)
        try FileManager.default.createDirectory(at: auth.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture sign-in".utf8).write(to: auth)
        try Data("fixture hook".utf8).write(to: auth.deletingLastPathComponent().appendingPathComponent("settings.json"))
        let environment = try ManualReviewAgy.environment(in: isolated, inheriting: ["HOME": home.path, "PATH": "/usr/bin",
            "XDG_CONFIG_HOME": "/person/config", "UNRELATED": "private"])
        #expect(environment["HOME"] == isolated.path)
        #expect(environment["XDG_CONFIG_HOME"] != "/person/config" && environment["UNRELATED"] == nil)
        let copy = isolated.appendingPathComponent(credentials)
        #expect(try Data(contentsOf: copy) == Data("fixture sign-in".utf8))
        #expect(try copy.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(!FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().appendingPathComponent("settings.json").path))
    }

    @Test(arguments: AgentKind.allCases) func manualInvocationUsesTheDraftChoices(_ agent: AgentKind) throws {
        let review = ManualReview(repository: "/project", branch: "topic", head: "abc", target: nil,
                                  agent: agent, model: "fixture", effort: "low", context: nil)
        let workspace = URL(fileURLWithPath: "/review"), output = URL(fileURLWithPath: "/answer")
        let invocation = try review.invocation(workspace: workspace, answerFile: output, profile: "trusted")
        #expect(invocation.executable == agent.harness.executable)
        for arg in agent.harness.modelArguments(model: "fixture", reasoning: "low") {
            #expect(invocation.arguments.contains(arg))
        }
        #expect(invocation.answerFile == (agent == .codex ? output.path : nil))
    }

    @Test func emptyRangeAndUnavailableOriginHaveDistinctOutcomes() throws {
        let path = try GitFixture.makeRepo(prefix: "review-target-")
        let scratch = try ScratchFolder.make("review-target-output-")
        defer { try? FileManager.default.removeItem(atPath: path); try? FileManager.default.removeItem(at: scratch) }
        let git = GitRunner.hermetic(), repo = Repository(path, git: git)
        let head = try git.run(["rev-parse", "HEAD"], in: path)
        #expect(try repo.prepareManualReview(head: head, target: "main", in: scratch.appendingPathComponent("local")).empty)
        try git.run(["remote", "add", "origin", scratch.appendingPathComponent("absent.git").path], in: path)
        let failure = #expect(throws: ManualReviewError.self) {
            try repo.prepareManualReview(head: head, target: "main", in: scratch.appendingPathComponent("remote"))
        }
        #expect(failure?.localizedDescription.contains("refs/heads/main on origin") == true)
    }

    @Test func movingTheBranchAfterSubmissionPreservesTheDiffAndCaller() async throws {
        let git = GitRunner.hermetic()
        let path = try GitFixture.makeRepo(prefix: "review-moving-")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let repo = Repository(path, git: git), root = URL(fileURLWithPath: path)
        let caller = root.appendingPathComponent("caller")
        let feature = root.appendingPathComponent("feature")
        try Data("committed caller".utf8).write(to: caller)
        try git.run(["add", "caller"], in: path)
        try git.run(["commit", "-qm", "caller"], in: path)
        try git.run(["switch", "-qc", "topic"], in: path)
        try Data("first change".utf8).write(to: feature)
        try git.run(["add", "feature"], in: path)
        try git.run(["commit", "-qm", "feature"], in: path)
        let head = try git.run(["rev-parse", "HEAD"], in: path)
        let expected = try git.run(["diff", "--binary", "--full-index", "main", head], in: path)
        var draft = ReviewDraft(mr: nil, agent: .claude, model: "fixture", reasoning: nil)
        draft.setBranch("topic")
        let pending = try repo.manualReview(draft: draft, checkout: path)
        defer { pending.discard() }
        try Data("later caller".utf8).write(to: caller)
        try Data("later change".utf8).write(to: feature)
        try git.run(["commit", "-qam", "advance after submission"], in: path)
        try await ManualReview.withClaim(at: pending.request) { review, folder in
            #expect(review.head == head)
            let input = try repo.prepareManualReview(head: review.head, target: review.target, in: folder)
            let patch = try String(contentsOf: input.workspace.appendingPathComponent("changes.patch"), encoding: .utf8)
            #expect(patch == expected + "\n")
            #expect(try Data(contentsOf: input.workspace.appendingPathComponent("source/caller")) == Data("committed caller".utf8))
        }
    }

    @Test func freshTargetUsesProjectTransportWithoutUpdatingRefs() throws {
        let git = GitRunner.hermetic()
        let root = try ScratchFolder.make("review-remote-")
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = root.appendingPathComponent("upstream"), project = root.appendingPathComponent("project")
        try GitFixture.initRepo(at: upstream.path)
        try git.run(["clone", "-q", upstream.path, project.path], in: root.path)
        try git.run(["checkout", "-qb", "topic"], in: project.path)
        try Data("topic".utf8).write(to: project.appendingPathComponent("feature"))
        try git.run(["add", "feature"], in: project.path)
        try git.run(["commit", "-qm", "topic"], in: project.path)
        let fork = try git.run(["rev-parse", "origin/main"], in: project.path)
        let head = try git.run(["rev-parse", "HEAD"], in: project.path)
        try git.run(["commit", "--allow-empty", "-qm", "target moved"], in: upstream.path)
        let fresh = try git.run(["rev-parse", "HEAD"], in: upstream.path)
        try git.run(["remote", "set-url", "origin", "fixture:upstream"], in: project.path)
        try git.run(["config", "url." + root.path + "/.insteadOf", "fixture:"], in: project.path)
        let refs = try git.run(["show-ref"], in: project.path)
        let fetchHead = project.appendingPathComponent(".git/FETCH_HEAD")
        try Data("present before review".utf8).write(to: fetchHead)
        let before = try Data(contentsOf: fetchHead)
        let input = try Repository(project.path, git: git).prepareManualReview(head: head, target: "main", in: root)
        #expect(input.base == fork && input.target == fresh)
        #expect(try git.run(["show-ref"], in: project.path) == refs)
        #expect(try Data(contentsOf: fetchHead) == before)
        #expect(try Repository(project.path, git: git).commit(fresh) == nil)
    }
}

extension ManualReviewTests {
    @Test func agyHookOnlyAdmitsTheTrustedInputs() throws {
        let folder = try ScratchFolder.make("trusted-reader-")
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let file = source.appendingPathComponent("caller")
        try Data().write(to: file)
        let link = source.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/")
        func permits(_ tool: String, _ path: String) throws -> Bool {
            let json: JSONValue = ["toolCall": ["name": .string(tool), "args": ["Path": .string(path)]]]
            return ManualReviewAgy.permits(try JSONEncoder().encode(json), workspace: folder)
        }
        #expect(try permits("read_file", file.path))
        #expect(try !permits("read_file", link.path))
        #expect(try !permits("read_file", "../claimed.json"))
        for tool in ["write_file", "edit_file", "run_command", "invoke_subagent", "manage_task"] {
            #expect(try !permits(tool, file.path))
        }
        let name = try ManualReviewAgy.install(in: folder, executable: URL(fileURLWithPath: "/fixture/AiTerm"))
        let definition = folder.appendingPathComponent(".agents/agents/" + name + "/agent.md")
        let profile = try String(contentsOf: definition, encoding: .utf8)
        #expect(profile.contains("tools: [read_file]"))
        #expect(profile.contains("inheritCustomizations: false"))
        #expect(profile.contains("hooks: [read-policy.json]"))
    }

    @Test func aStagedRequestCanOnlyBeClaimedOnce() async throws {
        let review = ManualReview(repository: "/", branch: "topic", head: "abc", target: nil, agent: .claude,
                                  model: "sonnet", effort: "high", context: "focus")
        let first = try review.stage(), other = try review.stage()
        defer { other.discard() }
        let claimed = try await ManualReview.withClaim(at: first.request) { request, _ in
            first.discard()
            let past = Date(timeIntervalSinceNow: -90000)
            for folder in [first.folder, other.folder] {
                try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: folder.path)
            }
            let next = try review.stage()
            defer { next.discard() }
            #expect(!FileManager.default.fileExists(atPath: other.folder.path))
            #expect(FileManager.default.fileExists(atPath: first.folder.path))
            return request.head
        }
        #expect(claimed == review.head)
        #expect(!FileManager.default.fileExists(atPath: first.folder.path))
        #expect(!FileManager.default.fileExists(atPath: other.request.path))
        await #expect(throws: ManualReviewError.self) {
            try await ManualReview.withClaim(at: first.request) { _, _ in }
        }
    }
}

extension ManualReviewTests {
    @Test(arguments: [true, false]) func checkoutPreparesTheBranchBeforeTheReview(localBranch: Bool) async throws {
        let git = GitRunner.hermetic(), fm = FileManager.default
        let root = try ScratchFolder.make("review-prepare-")
        defer { try? fm.removeItem(at: root) }
        let upstream = root.appendingPathComponent("origin"), clone = root.appendingPathComponent("project")
        try GitFixture.initRepo(at: upstream.path)
        try git.run(["branch", "topic"], in: upstream.path)
        try git.run(["clone", "-q", upstream.path, clone.path], in: root.path)
        if localBranch { try git.run(["branch", "topic", "origin/topic"], in: clone.path) }
        try git.run(["switch", "topic"], in: upstream.path)
        try Data("new revision".utf8).write(to: upstream.appendingPathComponent("file"))
        try git.run(["add", "file"], in: upstream.path)
        try git.run(["commit", "-qm", "posted change"], in: upstream.path)
        let head = try git.run(["rev-parse", "HEAD"], in: upstream.path)
        let project = Project.make(name: "Demo", path: clone.path)
        var draft = ReviewDraft(mr: nil, agent: .codex, model: "sample-model", reasoning: "low")
        draft.setBranch("topic")
        draft.setTitle("Read the change")
        let made = try await TaskWorkflow(git: git).createManualReview(draft: draft, project: project, reserved: [], executable: root)
        #expect(try git.run(["rev-parse", "refs/heads/topic"], in: clone.path) == head)
        let refs = try git.run(["show-ref"], in: clone.path)
        let tree = try git.run(["worktree", "list", "--porcelain"], in: clone.path)
        let pending = try #require(made.manualReview)
        try await ManualReview.withClaim(at: pending.request) { review, folder in
            #expect(review.head == head && review.agent == .codex && review.effort == "low" && review.model == "sample-model")
            _ = try Repository(clone.path, git: git).prepareManualReview(head: head, target: nil, in: folder)
        }
        #expect(try git.run(["show-ref"], in: clone.path) == refs)
        #expect(try git.run(["worktree", "list", "--porcelain"], in: clone.path) == tree)
    }
}
