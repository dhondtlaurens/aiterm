import Foundation

public enum ItemProjectMapper {
    /// Several projects are deliberately retained: the Operator chooses among their Jira links. A run's project is the
    /// one its schedule names (`signals`).
    public static func projects(for item: ItemRef, in projects: [Project], signals: [Signal] = []) -> [Project] {
        switch item {
        case .ticket(let ticket):
            guard let site = URL(string: ticket.site), let separator = ticket.key.lastIndex(of: "-") else { return [] }
            let key = String(ticket.key[..<separator]).uppercased()
            return projects.filter { project in
                project.jiraProjects.contains { $0.key.uppercased() == key && JiraConfig.normalizedSiteURL($0.siteURL) == JiraConfig.normalizedSiteURL(site) }
            }
        case .mergeRequest(let request): return matching(remote: request.remote, projects: projects)
        case .run(let run):
            guard let id = signals.first(where: { $0.id == run.signal })?.start.project else { return [] }
            return projects.filter { $0.id == id }
        }
    }
    private static func matching(remote: String, projects: [Project]) -> [Project] {
        guard let key = ItemRef.repository(remote) else { return [] }
        return projects.filter { $0.remoteUrl.flatMap(ItemRef.repository) == key }
    }
}
