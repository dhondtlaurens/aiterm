import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The prompt's `@` completions: which of the project's paths are offered, in what order, and how a
/// pick is written.
@Suite(.blocking) struct ProjectFilesTests {
    let git = GitRunner.hermetic()

    private func write(_ text: String, _ path: String, in root: String) throws {
        let url = URL(fileURLWithPath: root + "/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func names(_ items: [AgentCompletion]) -> [String] { items.map(\.name) }

    /// A checkout offers what git tracks — what the task's new worktree will have — and every
    /// folder above it; an untracked or ignored file is not there to open.
    @Test func aCheckoutOffersItsTrackedFilesAndTheirFolders() throws {
        let repo = try GitFixture.makeRepo(prefix: "pf-")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try write("", "README.md", in: repo)
        try write("", "app/Sources/main.swift", in: repo)
        try write("build/\n", ".gitignore", in: repo)
        try git.run(["add", "."], in: repo)
        try write("", "build/out.o", in: repo)
        try write("", "scratch.txt", in: repo)

        let index = ProjectFiles.list(in: repo, git: git)
        #expect(names(index.matches("", limit: 20))
            == [".gitignore", "README.md", "app/", "app/Sources/", "app/Sources/main.swift"].sorted(by: Self.order))
        #expect(index.matches("app/Sources/main.swift").first?.kind == .file)
        #expect(index.matches("app/").first?.kind == .folder)
    }

    /// A folder that is not a git checkout is walked, its hidden entries and dependency trees left
    /// out.
    @Test func aPlainFolderIsWalked() throws {
        let folder = try GitFixture.folder("pf-plain-")
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try write("", "notes/todo.md", in: folder)
        try write("", ".secret", in: folder)
        try write("", "node_modules/pkg/index.js", in: folder)

        let index = ProjectFiles.list(in: folder, git: git)
        #expect(names(index.matches("", limit: 20)) == ["notes/", "notes/todo.md"])
    }

    /// The order the index was built in: shallow first, then folders before files, then by name.
    private static func order(_ a: String, _ b: String) -> Bool {
        let da = a.split(separator: "/").count, db = b.split(separator: "/").count
        if da != db { return da < db }
        if a.hasSuffix("/") != b.hasSuffix("/") { return a.hasSuffix("/") }
        return a < b
    }

    /// The top level first, so an empty query lists it; folders before files at each depth.
    @Test func theIndexRunsShallowFirstWithFoldersBeforeFiles() {
        let index = FileIndex(paths: ["src/b.swift", "README.md", "src/a/x.swift", "Package.swift"])
        #expect(names(index.matches("", limit: 20))
            == ["src/", "Package.swift", "README.md", "src/a/", "src/b.swift", "src/a/x.swift"])
    }

    /// A path that starts with the query comes first, then one whose own name does, then one that
    /// holds it anywhere; case is ignored.
    @Test func matchingRanksThePathThenTheNameThenAnywhere() {
        let index = FileIndex(paths: ["docs/readme-old.txt", "README.md", "app/Sources/Reader.swift", "lib/thread.c"])
        #expect(names(index.matches("rea")) == ["README.md", "docs/readme-old.txt", "app/Sources/Reader.swift", "lib/thread.c"])
        #expect(names(index.matches("APP/S")) == ["app/Sources/", "app/Sources/Reader.swift"])
    }

    /// `@app/` lists what is inside `app/`, not `app/` again.
    @Test func theFolderTheQueryNamesIsLeftOut() {
        let index = FileIndex(paths: ["app/main.swift", "app/lib/util.swift"])
        #expect(names(index.matches("app/")) == ["app/lib/", "app/main.swift", "app/lib/util.swift"])
    }

    @Test func matchingStopsAtTheLimit() {
        let index = FileIndex(paths: (0..<50).map { "file\($0).txt" })
        #expect(index.matches("file").count == SkillCatalog.matchLimit)
    }

    /// A pick is its `@` mention, a space in it escaped so it stays one word.
    @Test func aPickIsWrittenAsItsMention() {
        let file = AgentCompletion(name: "docs/My Notes.md", kind: .file, detail: nil, source: .project)
        let folder = AgentCompletion(name: "app/Sources/", kind: .folder, detail: nil, source: .project)
        #expect(ProjectFiles.mention(of: file) == #"@docs/My\ Notes.md"#)
        for agent in AgentKind.allCases {
            #expect(SkillCatalog.invocation(of: folder, for: agent) == "@app/Sources/")
        }
    }
}
