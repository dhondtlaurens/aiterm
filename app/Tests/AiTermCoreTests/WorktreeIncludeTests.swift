import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// `.worktreeinclude`, against real repositories: what it selects in the project's checkout, what
/// that costs git, and how each file is copied into a new worktree.
@Suite(.blocking) struct WorktreeIncludeTests {
    let git = GitRunner.hermetic()
    let repo: String

    init() throws { repo = try GitFixture.makeRepo(prefix: "wi-") }

    /// `text` at `path` under `root` (the project's checkout unless named), its folders made.
    private func write(_ text: String, _ path: String, in root: String? = nil) throws {
        let url = URL(fileURLWithPath: (root ?? repo) + "/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

    // -- what it selects -------------------------------------------------------------

    /// No file is the common case, and costs nothing: git is not asked.
    @Test func aProjectWithoutTheFileSelectsNothingWithoutAskingGit() throws {
        try write("A=1", ".env")
        let recording = RecordingGitRunner(forwardingTo: git)
        #expect(try WorktreeInclude.matches(in: Repository(repo, git: recording)).isEmpty)
        #expect(recording.calls.isEmpty)
    }

    /// Only what git ignores *and* the file lists: a listed file git would commit stays behind, an
    /// ignored file the file does not list stays behind, a tracked file is never a candidate, and a
    /// folder pattern brings what is in it, at any depth. Names with a space or an accent come
    /// through as they are, not as git quotes them.
    @Test func selectsTheUntrackedFilesItListsThatGitIgnores() throws {
        try write(".env\ncerts/\n*.log\nnode_modules/\n", ".gitignore")
        try write(".env\ncerts/\nnotes.txt\nconfig/*.json\n", ".worktreeinclude")
        try write("{}", "config/app.json")
        try git.run(["add", ".gitignore", ".worktreeinclude", "config/app.json"], in: repo)
        try git.run(["commit", "-q", "-m", "files"], in: repo)
        for (text, path) in [("A=1", ".env"), ("k", "certs/dev key.pem"), ("c", "certs/café.pem"), ("ca", "certs/sub/ca.pem"),
                             ("n", "notes.txt"), ("{}", "config/local.json"), ("log", "app.log"),
                             ("x", "node_modules/pkg/index.js"), ("B=2", "packages/api/.env")] {
            try write(text, path)
        }
        #expect(Set(try WorktreeInclude.matches(in: Repository(repo, git: git)))
                == [".env", "certs/dev key.pem", "certs/café.pem", "certs/sub/ca.pem", "packages/api/.env"])
    }

    /// The two listings, and only those: the second is `git status`'s untracked files, which never
    /// enters an ignored `node_modules`. `--ignored --exclude-standard` would list every file in it.
    @Test func listsWithTheTwoCheapCommandsOnly() throws {
        try write(".env\nnode_modules/\n", ".gitignore")
        try write(".env\n", ".worktreeinclude")
        try write("A=1", ".env")
        try write("x", "node_modules/pkg/index.js")
        let recording = RecordingGitRunner(forwardingTo: git)
        #expect(try WorktreeInclude.matches(in: Repository(repo, git: recording)) == [".env"])
        #expect(recording.calls.map(\.args) == [
            ["ls-files", "-z", "--others", "--ignored", "--exclude-from=" + repo + "/.worktreeinclude"],
            ["ls-files", "-z", "--others", "--exclude-standard"],
        ])
    }

    /// A file that selects nothing — comments only, or patterns nothing matches — costs one listing.
    @Test func aFileThatSelectsNothingCostsOneListing() throws {
        try write("# nothing yet\n\n", ".worktreeinclude")
        try write("A=1", ".env")
        let recording = RecordingGitRunner(forwardingTo: git)
        #expect(try WorktreeInclude.matches(in: Repository(repo, git: recording)).isEmpty)
        #expect(recording.calls.count == 1)
    }

    /// Another worktree is never a source: a live one is a repository git does not enter, and a
    /// folder a removal left under `.worktrees/` — which git does enter — is skipped by name. A
    /// nested repository is listed as a folder, which is never copied.
    @Test func neverSelectsFromAnotherWorktreeOrANestedRepository() throws {
        try write(".env\n", ".gitignore")
        try write(".env\nvendor/\n", ".worktreeinclude")
        try write("A=1", ".env")
        try ExcludeFile.append(".worktrees/", to: try #require(ExcludeFile.url(forWorktreeOrRepo: repo, git: git)))
        try git.run(["worktree", "add", "-q", "-b", "other", repo + "/.worktrees/other"], in: repo)
        try write("O=1", ".worktrees/other/.env")
        try write("S=1", ".worktrees/stale/.env")
        try GitFixture.initRepo(at: repo + "/vendor/lib")
        try write("N=1", "vendor/lib/.env")
        #expect(try WorktreeInclude.matches(in: Repository(repo, git: git)) == [".env"])
    }

    /// A git that could not be asked has not said "nothing": `matches` throws, and the copy says
    /// it could not read the file rather than claiming everything came.
    @Test func gitThatCannotBeAskedIsNoAnswer() throws {
        try write(".env\n", ".worktreeinclude")
        let flaky = FlakyGitRunner(git)
        flaky.failing = true
        #expect(throws: GitError.self) { try WorktreeInclude.matches(in: Repository(repo, git: flaky)) }
        #expect(WorktreeInclude.copy(from: Repository(repo, git: flaky), into: try GitFixture.folder("wi-wt-")) == .unread)
    }

    // -- the copy --------------------------------------------------------------------

    @Test func copiesEachFileToItsOwnPathMakingItsFolders() throws {
        try write("A=1", ".env")
        try write("ca", "certs/sub/ca.pem")
        let worktree = try GitFixture.folder("wi-wt-")
        #expect(WorktreeInclude.copy([".env", "certs/sub/ca.pem"], from: repo, into: worktree) == .complete)
        #expect(try read(worktree + "/.env") == "A=1")
        #expect(try read(worktree + "/certs/sub/ca.pem") == "ca")
    }

    /// What the worktree has is its own: a file its branch tracks, one a checkout hook wrote, or a
    /// symlink to nothing — none is replaced, and none counts as a failure.
    @Test func neverOverwritesWhatTheWorktreeAlreadyHas() throws {
        try write("A=1", ".env")
        try write("B=2", ".env.local")
        let worktree = try GitFixture.folder("wi-wt-")
        try write("mine", ".env", in: worktree)
        try FileManager.default.createSymbolicLink(atPath: worktree + "/.env.local", withDestinationPath: "/nonexistent")
        #expect(WorktreeInclude.copy([".env", ".env.local"], from: repo, into: worktree) == .complete)
        #expect(try read(worktree + "/.env") == "mine")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: worktree + "/.env.local") == "/nonexistent")
    }

    /// One file that cannot be read is named; the others still come.
    @Test func aFileThatCannotBeCopiedIsNamedAndTheRestStillCome() throws {
        try write("A=1", ".env")
        try write("k", "certs/dev.pem")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: repo + "/.env")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: repo + "/.env") }
        let worktree = try GitFixture.folder("wi-wt-")
        #expect(WorktreeInclude.copy([".env", "certs/dev.pem"], from: repo, into: worktree) == .notCopied([".env"]))
        #expect(try read(worktree + "/certs/dev.pem") == "k")
    }

    /// A branch can track `certs` as a symlink out of the worktree: a key is never written through it.
    @Test func neverWritesThroughASymlinkOutOfTheWorktree() throws {
        try write("k", "certs/dev.pem")
        let worktree = try GitFixture.folder("wi-wt-"), elsewhere = try GitFixture.folder("wi-elsewhere-")
        try FileManager.default.createSymbolicLink(atPath: worktree + "/certs", withDestinationPath: elsewhere)
        #expect(WorktreeInclude.copy(["certs/dev.pem"], from: repo, into: worktree) == .notCopied(["certs/dev.pem"]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere).isEmpty)
    }

    /// The whole job, as a create runs it: listed, then copied.
    @Test func copyingFromARepositoryListsThenCopies() throws {
        try write(".env\n", ".gitignore")
        try write(".env\n", ".worktreeinclude")
        try write("A=1", ".env")
        let worktree = try GitFixture.folder("wi-wt-")
        #expect(WorktreeInclude.copy(from: Repository(repo, git: git), into: worktree) == .complete)
        #expect(try read(worktree + "/.env") == "A=1")
    }
}
