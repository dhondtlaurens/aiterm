import Foundation
import Testing
@testable import AiTermCore

/// What `read_task` with `what: diff` answers instead of the whole diff (spec §9): each file's patch cut to a size,
/// the whole cut to another, and a lockfile summarised, never inlined.
@Suite struct DiffDigestTests {
    /// A one-hunk diff of `path` that adds `lines` lines of `text`.
    func patch(_ path: String, lines: Int = 1, text: String = "x") -> String {
        "diff --git a/\(path) b/\(path)\nindex 111..222 100644\n--- a/\(path)\n+++ b/\(path)\n@@ -1,0 +1,\(lines) @@\n"
            + (0..<lines).map { _ in "+" + text }.joined(separator: "\n") + "\n"
    }

    static let lockfileDiff = """
        diff --git a/package-lock.json b/package-lock.json
        index 111..222 100644
        --- a/package-lock.json
        +++ b/package-lock.json
        @@ -10,7 +10,7 @@
             "node_modules/vue": {
        -      "version": "3.4.0",
        +      "version": "3.5.0",
               "resolved": "https://registry.npmjs.org/vue/-/vue-3.5.0.tgz"
             },
        @@ -40,7 +40,7 @@
             "node_modules/vite/node_modules/esbuild": {
        -      "version": "0.20.0",
        +      "version": "0.21.0",
               "dev": true
             },
             "node_modules/vite": {
        -      "version": "5.0.0",
        +      "version": "5.1.0",
               "dev": true
             },
             "node_modules/lodash": {
               "version": "4.17.21",
               "license": "MIT"
        +      "funding": "none"
             },

        """

    @Test func aLockfileIsSummarisedNotInlined() throws {
        let digest = DiffDigest.build(diff: Self.lockfileDiff + patch("src/a.ts", lines: 2))
        #expect(digest.files.map(\.path) == ["package-lock.json", "src/a.ts"])
        let lock = digest.files[0]
        #expect(lock.patch == nil)
        let summary = try #require(lock.summary)
        #expect(summary.hasPrefix("+4 \u{2212}3 lines; versions changed: "))
        #expect(summary.contains("vue") && summary.contains("vite") && summary.contains("esbuild"))
        #expect(!summary.contains("lodash"), "a block whose version did not change is not named")
        let source = digest.files[1]
        #expect(source.patch?.contains("+x") == true && source.summary == nil && !source.truncated)
        #expect(!digest.truncated)
    }

    @Test(arguments: ["yarn.lock", "pnpm-lock.yaml", "Package.resolved", "poetry.lock", "uv.lock", "Cargo.lock", "composer.lock",
                      "Gemfile.lock", "app/Package.resolved", "web/package-lock.json"])
    func everyLockfileIsMatchedOnItsLastPathComponent(_ path: String) {
        let file = DiffDigest.build(diff: patch(path, lines: 3)).files[0]
        #expect(file.patch == nil && file.summary?.hasPrefix("+3 \u{2212}0 lines") == true)
        #expect(DiffDigest.lockfiles.contains((path as NSString).lastPathComponent))
    }

    @Test func aFileThatMerelyEndsLikeALockfileIsAFile() {
        #expect(DiffDigest.build(diff: patch("not-yarn.lock.md")).files[0].patch != nil)
        #expect(DiffDigest.build(diff: patch("src/yarn.lock.ts")).files[0].patch != nil)
    }

    @Test func onlyNpmsLockfileNamesVersions() throws {
        let other = Self.lockfileDiff.replacingOccurrences(of: "package-lock.json", with: "yarn.lock")
        #expect(try #require(DiffDigest.build(diff: other).files[0].summary) == "+4 \u{2212}3 lines")
    }

    @Test func versionNamesAreCappedAtThirty() throws {
        var diff = "diff --git a/package-lock.json b/package-lock.json\n--- a/package-lock.json\n+++ b/package-lock.json\n@@ -1,1 +1,1 @@\n"
        for i in 0..<35 { diff += " \"node_modules/pkg\(i)\": {\n-\"version\": \"1\",\n+\"version\": \"2\",\n" }
        let summary = try #require(DiffDigest.build(diff: diff).files[0].summary)
        #expect(summary.contains("pkg29") && !summary.contains("pkg30") && summary.hasSuffix(" and 5 more"))
    }

    @Test func eachFileIsCapped() {
        let big = patch("src/big.ts", lines: 2_000, text: "xxxx")
        #expect(big.count > 10_000)
        let digest = DiffDigest.build(diff: big + patch("src/small.ts"), total: 100_000)
        #expect(digest.files[0].patch?.count == 6_000 && digest.files[0].truncated)
        #expect(digest.files[1].truncated == false && digest.files[1].patch?.contains("+x") == true)
        #expect(digest.truncated)
    }

    @Test func theWholeDigestIsCapped() {
        let diff = (0..<10).map { patch("src/f\($0).ts", lines: 600, text: "xxxxxxxx") }.joined()
        let digest = DiffDigest.build(diff: diff)
        let carried = digest.files.compactMap(\.patch).reduce(0) { $0 + $1.count }
        #expect(carried <= 30_000 && digest.truncated)
        #expect(digest.files.map(\.path).count == 10, "a file past the cap is still listed")
        let last = digest.files[9]
        #expect(last.patch == nil && last.truncated && last.summary?.hasPrefix("+600 \u{2212}0 lines") == true)
    }

    @Test func anEmptyDiffHasNoFiles() {
        let digest = DiffDigest.build(diff: "")
        #expect(digest.files.isEmpty && !digest.truncated)
    }

    @Test func aRenamedFileIsNamedByWhereItWent() {
        let diff = "diff --git a/old.ts b/new.ts\nsimilarity index 90%\nrename from old.ts\nrename to new.ts\n"
        #expect(DiffDigest.build(diff: diff).files.map(\.path) == ["new.ts"])
    }
}
