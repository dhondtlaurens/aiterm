import Foundation
import Testing
import AiTermCore
@testable import AiTerm

/// A linked project's badge counts every Jira project and offers each in link order.
/// The badges' own pixels belong to `Badge`; these checks cover the presentation and destinations.
@Suite struct ProjectJiraBadgeTests {
    private static let site = URL(string: "https://example.atlassian.net")!
    private static let frontend = JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: site)
    private static let portal = JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: site)
    private static let web = JiraProjectRef(id: "10003", key: "WEB", name: "Website", siteURL: site)

    private func project(jira: [JiraProjectRef]) -> Project {
        Project(id: UUID(), name: "AiTerm", path: "/tmp/aiterm", provider: .git, remoteUrl: nil,
                addedAt: Date(), collapsed: false, jiraProjects: jira)
    }

    @Test func testAnUnlinkedProjectWearsNoBadge() {
        #expect(ProjectJiraBadge.badge(for: project(jira: [])) == nil)
    }

    @Test func testAProjectLinkedToOneShowsACountAndOffersItsLink() throws {
        let badge = try #require(ProjectJiraBadge.badge(for: project(jira: [Self.frontend])))
        #expect(badge.label == "1")
        #expect(badge.items == [
            .init(title: "SHOP · Storefront", url: URL(string: "https://example.atlassian.net/browse/SHOP")!),
        ])
        #expect(badge.help == "Jira · SHOP Storefront")
        #expect(badge.accessibilityLabel == "1 Jira project: SHOP")
    }

    @Test func testAProjectLinkedToSeveralCountsAndOffersEveryProject() throws {
        let badge = try #require(ProjectJiraBadge.badge(for: project(jira: [Self.frontend, Self.portal, Self.web])))
        #expect(badge.label == "3")
        #expect(badge.items == [
            .init(title: "SHOP · Storefront", url: URL(string: "https://example.atlassian.net/browse/SHOP")!),
            .init(title: "PAY · Payments", url: URL(string: "https://example.atlassian.net/browse/PAY")!),
            .init(title: "WEB · Website", url: URL(string: "https://example.atlassian.net/browse/WEB")!),
        ])
        #expect(badge.help == "Jira · SHOP Storefront · PAY Payments · WEB Website")
        #expect(badge.accessibilityLabel == "3 Jira projects: SHOP, PAY and WEB")
    }

    @Test func testTurningTheCountOffKeepsEveryMenuLink() throws {
        let linked = project(jira: [Self.frontend, Self.portal])
        let badge = try #require(ProjectJiraBadge.badge(for: linked, showsCount: false))
        #expect(badge.label == nil)
        #expect(badge.items == ProjectJiraBadge.badge(for: linked)?.items)
        #expect(badge.accessibilityLabel == "2 Jira projects: SHOP and PAY")
    }
}
