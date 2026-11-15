import Foundation

public enum ItemProjectMapper {
    /// Several projects are deliberately retained: the Operator chooses among their Jira links.
    public static func projects(for item: ItemRef, in projects: [Project]) -> [Project] {
        switch item {
        case .ticket(let ticket):
            guard let site = URL(string: ticket.site), let separator = ticket.key.lastIndex(of: "-") else { return [] }
            let key = String(ticket.key[..<separator]).uppercased()
            return projects.filter { project in
                project.jiraProjects.contains { $0.key.uppercased() == key && JiraConfig.normalizedSiteURL($0.siteURL) == JiraConfig.normalizedSiteURL(site) }
            }
        case .mergeRequest(let request): return matching(remote: request.remote, projects: projects)
        case .branch(let branch): return matching(remote: branch.remote, projects: projects)
        case .unknown: return []
        }
    }
    private static func matching(remote: String, projects: [Project]) -> [Project] {
        guard let key = ItemRef.repository(remote) else { return [] }
        return projects.filter { $0.remoteUrl.flatMap(ItemRef.repository) == key }
    }
}
