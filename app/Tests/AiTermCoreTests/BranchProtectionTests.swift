import Testing
@testable import AiTermCore

/// A host's branch-name patterns: GitLab's `*` spans any characters; GitHub's (fnmatch with
/// FNM_PATHNAME) stops at `/` unless doubled.
@Suite struct BranchProtectionTests {
    @Test func patternsMatchAsEachHostReadsThem() {
        #expect(BranchProtection.matches("main", "main", starCrossesSlash: true))
        #expect(!BranchProtection.matches("main", "maintenance", starCrossesSlash: true))
        #expect(BranchProtection.matches("release/*", "release/2026/10", starCrossesSlash: true))
        #expect(!BranchProtection.matches("feat/*", "feat/a/b", starCrossesSlash: false))
        #expect(BranchProtection.matches("feat/*", "feat/pluto-231", starCrossesSlash: false))
        #expect(BranchProtection.matches("feat/**", "feat/a/b", starCrossesSlash: false))
        #expect(BranchProtection.matches("v[0-9]*", "v1.2", starCrossesSlash: false))
        #expect(!BranchProtection.matches("v[!0-9]*", "v1.2", starCrossesSlash: false))
        #expect(BranchProtection.matches("hot?ix", "hotfix", starCrossesSlash: false))
        #expect(!BranchProtection.matches("a.b", "axb", starCrossesSlash: true), "a dot is a dot")
    }

    @Test func matchingIsCaseSensitiveAndSpansTheWholeName() {
        #expect(!BranchProtection.matches("main", "Main", starCrossesSlash: true))
        #expect(!BranchProtection.matches("release/*", "Release/1", starCrossesSlash: true))
        #expect(!BranchProtection.matches("main", "main\n", starCrossesSlash: true), "a trailing newline is no match for `$`")
        #expect(BranchProtection.matches("*", "any/thing", starCrossesSlash: true))
        #expect(!BranchProtection.matches("*", "any/thing", starCrossesSlash: false))
        #expect(BranchProtection.matches("a[[]b", "a[b", starCrossesSlash: false), "`[` in a class is a character")
        #expect(BranchProtection.matches("a[&&]b", "a&b", starCrossesSlash: false), "`&&` in a class is two characters")
    }

    /// A pattern AiTerm cannot read is neither a match nor a miss: `evaluate` says so, and `matches`,
    /// which can only answer yes or no, answers the one that pushes nothing.
    @Test func aPatternThatCannotBeEvaluatedIsNotAMiss() throws {
        for pattern in ["v[z-a]*", "v[]", "x[!]"] {
            #expect(throws: ProtectionUnknown.unreadable("AiTerm cannot read the branch pattern \(pattern)")) {
                try BranchProtection.evaluate(pattern, "v1", starCrossesSlash: true)
            }
            #expect(BranchProtection.matches(pattern, "v1", starCrossesSlash: true))
        }
        #expect(try BranchProtection.evaluate("v[0-9]*", "v1", starCrossesSlash: true))
        #expect(try !BranchProtection.evaluate("v[0-9]*", "w1", starCrossesSlash: true))
    }
}

