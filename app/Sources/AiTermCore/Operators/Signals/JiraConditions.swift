import Foundation

public struct JiraConditions: Codable, Equatable, Sendable {
    public var labels: [String]
    public var inOpenSprints: Bool
    /// `me` compiles to currentUser(); every other value is quoted.
    public var assignee: String?
    public var statuses: [String]
    public var projects: [String]
    public var jql: String?
    public init(labels: [String] = [], inOpenSprints: Bool = false, assignee: String? = nil,
                statuses: [String] = [], projects: [String] = [], jql: String? = nil) {
        self.labels = labels; self.inOpenSprints = inOpenSprints; self.assignee = assignee
        self.statuses = statuses; self.projects = projects; self.jql = jql
    }
}
