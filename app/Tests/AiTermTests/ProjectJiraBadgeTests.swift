import Foundation
import Testing
import AiTermCore
@testable import AiTerm

/// The rule a project row follows: one badge per linked Jira project, in the order they were
/// linked, each pointing at its own project; a project linked to none wears nothing. The badges'
/// own pixels belong to `Badge`; what is tested here is only which badges a project gets and where
/// each one points.
@Suite struct ProjectJiraBadgeTests {
    private static let site = URL(string: "https://example.atlassian.net")!
    private static let frontend = JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: site)
    private static let portal = JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: site)

    private func project(jira: [JiraProjectRef]) -> Project {
        Project(id: UUID(), name: "AiTerm", path: "/tmp/aiterm", provider: .git, remoteUrl: nil,
                addedAt: Date(), collapsed: false, jiraProjects: jira)
    }

    @Test func testAnUnlinkedProjectWearsNoBadge() {
        #expect(ProjectJiraBadge.badges(for: project(jira: [])).isEmpty)
    }

    @Test func testEachLinkedProjectWearsItsOwnKeyAndLinksToItsOwnProject() {
        let badges = ProjectJiraBadge.badges(for: project(jira: [Self.frontend, Self.portal]))
        #expect(badges.map(\.key) == ["SHOP", "PAY"])
        #expect(badges.map(\.label) == ["SHOP", "PAY"])
        #expect(badges.map(\.url.absoluteString) == ["https://example.atlassian.net/browse/SHOP",
                                                     "https://example.atlassian.net/browse/PAY"])
        // The key is all the row shows, so the project's name only reaches the reader on hover.
        #expect(badges.map(\.help) == ["Storefront — https://example.atlassian.net/browse/SHOP",
                                       "Payments — https://example.atlassian.net/browse/PAY"])
    }
}
