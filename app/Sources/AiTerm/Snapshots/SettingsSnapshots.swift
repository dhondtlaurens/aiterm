import SwiftUI
import AiTermUI
import AiTermCore

#if DEBUG
/// The Jira projects sheet and every Settings tab.
@MainActor
enum SettingsSnapshots {
    static var all: [Snapshot] {
        [
            // Two projects linked and the picker's list down, leaving them out. Seeded rather than
            // loaded: `loadProjects` runs from `.task`, which the renderer never waits for.
            Snapshot("jira-project.png") {
                let project = Fixture().project
                return JiraProjectSheet(projectName: project.name, linked: project.jiraProjects, canSubmit: true,
                                        loadProjects: { jiraProjects }, submit: { _ in })
                    .seeded(projects: jiraProjects, open: true)
            },
        ] + SettingsTab.allCases.map { tab in
            // A Jira site and email typed in, no token yet.
            Snapshot("settings-\(tab.rawValue.lowercased()).png") {
                let jira = JiraConfig(siteURL: URL(string: "https://example.atlassian.net")!, email: "you@example.com", token: "")
                return settings(jira: jira, iterm: .connected(version: "3.7.2"), environment: ready, tab: tab)
            }
        } + [
            // The sheet clips a tab to its height, and the Interface tab runs on past it into the
            // keyboard section, so the whole tab is drawn once more at full length, on the sheet's
            // ground and inside its margins.
            Snapshot("settings-interface-full.png") {
                let preferences = Fixture.preferences
                return InterfaceSettingsPane(matchItermBackground: .constant(preferences.matchItermBackground),
                                             badgeDetails: .constant(preferences.badgeDetails),
                                             interfaceSize: .constant(preferences.interfaceSize))
                    .padding(Space.margin).frame(width: Sheet.width).background(Palette.surface)
            },
            // The iTerm card's other shape: a broken link, and the numbered steps that mend it.
            Snapshot("settings-iterm-off.png") {
                let apiOff = ItermEnvironment(installed: true, pythonAPIEnabled: false)
                return settings(jira: nil, iterm: .waitingForIterm, environment: apiOff, tab: .integrations)
                    .seeded(itermEnvironment: apiOff)
            },
            // “Fix with AI” on its own, in its four shapes: on with Claude, Codex installed beside
            // it; off, the select dimmed and still on Codex; nothing installed that can fix, so the
            // switch is off and disabled; and a chosen agent that is gone. Drawn last: an added
            // image goes after the ones before it (`Snapshots.regressionSet`).
            Snapshot("settings-fixer-claude.png") { fixerGroup(.agent(.claude), installed: [.claude, .codex]) },
            Snapshot("settings-fixer-off.png") { fixerGroup(.off(keeping: .codex), installed: [.claude, .codex, .grok]) },
            Snapshot("settings-fixer-none.png") { fixerGroup(.agent(.claude), installed: [.pi]) },
            // Codex chosen and since uninstalled: it stays chosen, not swapped for Claude, and says so.
            Snapshot("settings-fixer-missing.png") { fixerGroup(.agent(.codex), installed: [.claude]) },
            // Agents at once, at its default of two.
            Snapshot("settings-agents-at-once.png") {
                AgentsAtOnceGroup(count: .constant(2)).frame(width: Sheet.width - 2 * Space.margin)
            },
        ]
    }

    private static func fixerGroup(_ choice: FixerChoice, installed: Set<AgentKind>) -> some View {
        FixerSettingsGroup(choice: .constant(choice), installed: installed).frame(width: Sheet.width - 2 * Space.margin)
    }

    private static let site = URL(string: "https://example.atlassian.net")!
    private static let jiraProjects = [
        // The fixture project's two, by the same ids, as Jira would list them.
        JiraProjectRef(id: "10001", key: "SHOP", name: "Storefront", siteURL: site),
        JiraProjectRef(id: "10002", key: "PAY", name: "Payments", siteURL: site),
        JiraProjectRef(id: "3", key: "SUP", name: "Customer support", siteURL: site),
        JiraProjectRef(id: "4", key: "MOB", name: "Mobile", siteURL: site),
        JiraProjectRef(id: "5", key: "PLT", name: "Platform engineering", siteURL: site),
        JiraProjectRef(id: "6", key: "SEC", name: "Security", siteURL: site),
    ]
    private static let ready = ItermEnvironment(installed: true, pythonAPIEnabled: true)

    /// Settings on `tab`, its Agents tab on the fixture harnesses.
    private static func settings(jira: JiraConfig?, iterm: ItermConnection, environment: ItermEnvironment,
                                 tab: SettingsTab) -> SettingsView {
        SettingsView(jiraConfig: jira, gitLabConfig: nil, harnessModel: .preview(),
                     itermConnection: { iterm }, checkIterm: { environment },
                     preferences: Fixture.preferences, setMatchItermBackground: { _ in }, setInterfaceSize: { _ in },
                     initialTab: tab)
    }
}
#endif
