import Foundation
import Testing
import AiTermCore
@testable import AiTerm

/// The rule a project row follows: one Jira badge whatever it links. A project linked to one Jira
/// project wears that project's key and opens it; linked to several, it wears their count and
/// offers them in a menu, in the order they were linked; linked to none, it wears nothing. The
/// badge's own pixels belong to `Badge`; what is tested here is only what it says and where it
/// points.
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

    @Test func testAProjectLinkedToOneWearsItsKeyAndOpensIt() throws {
        let badge = try #require(ProjectJiraBadge.badge(for: project(jira: [Self.frontend])))
        #expect(badge.label == "SHOP")
        #expect(badge.target == .project(URL(string: "https://example.atlassian.net/browse/SHOP")!))
        // The key is all the row shows, so the project's name only reaches the reader on hover.
        #expect(badge.help == "Storefront — https://example.atlassian.net/browse/SHOP")
        #expect(badge.accessibilityLabel == nil)
    }

    @Test func testAProjectLinkedToSeveralWearsTheirCountAndOffersEachInAMenu() throws {
        let badge = try #require(ProjectJiraBadge.badge(for: project(jira: [Self.frontend, Self.portal, Self.web])))
        #expect(badge.label == "3")
        #expect(badge.target == .menu([
            .init(title: "SHOP — Storefront", url: URL(string: "https://example.atlassian.net/browse/SHOP")!),
            .init(title: "PAY — Payments", url: URL(string: "https://example.atlassian.net/browse/PAY")!),
            .init(title: "WEB — Website", url: URL(string: "https://example.atlassian.net/browse/WEB")!),
        ]))
        // A count says nothing on its own: the hover names every project, and VoiceOver every key.
        #expect(badge.help == "Jira · SHOP Storefront · PAY Payments · WEB Website")
        #expect(badge.accessibilityLabel == "3 Jira projects: SHOP, PAY and WEB")
    }

    @Test func testTurningTheProjectKeyOffStillCountsSeveralProjects() throws {
        // The switch drops a key; a count is not a key, and without it the mark could not say there
        // is a choice behind it.
        let several = try #require(ProjectJiraBadge.badge(for: project(jira: [Self.frontend, Self.portal]), showsKey: false))
        #expect(several.label == "2")
        let one = try #require(ProjectJiraBadge.badge(for: project(jira: [Self.frontend]), showsKey: false))
        #expect(one.label == nil)
    }
}
