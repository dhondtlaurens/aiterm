import Testing
@testable import AiTermCore

@Suite struct BranchTypeTests {
    /// Jira's own issue types, stock and common custom ones, land on the Conventional Commits type
    /// the work usually is. A Task is feature work in these projects, so it stays `feat`.
    @Test(arguments: [
        ("Bug", BranchType.fix), ("Defect", .fix), ("Incident", .fix), ("Production bug", .fix),
        ("Story", .feat), ("Epic", .feat), ("Task", .feat), ("Sub-task", .feat), ("Subtask", .feat),
        ("New Feature", .feat), ("Improvement", .feat),
        ("Chore", .chore), ("Maintenance", .chore), ("Tech Debt", .chore), ("Technical debt", .chore),
        ("Refactor", .chore), ("Documentation", .chore), ("Performance", .feat),
        ("Dependency", .chore), ("Dependencies", .chore), ("Upgrade", .chore), ("Bump", .chore), ("fix", .fix), ("feat", .feat),
    ])
    func testAJiraIssueTypeMapsToABranchType(issueType: String, expected: BranchType) {
        #expect(BranchType(issueType: issueType) == expected)
    }

    @Test func testAnUnknownOrMissingIssueTypeIsAFeature() {
        #expect(BranchType(issueType: "Spike") == .feat)
        #expect(BranchType(issueType: nil) == .feat)
        #expect(BranchType(issueType: "") == .feat)
    }

}
