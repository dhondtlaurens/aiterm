import Foundation

public enum JQL {
    public static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    public static func compile(_ conditions: JiraConditions) -> String {
        if let manual = conditions.jql?.trimmingCharacters(in: .whitespacesAndNewlines), !manual.isEmpty { return manual }
        var parts: [String] = []
        func add(_ field: String, _ values: [String]) {
            if !values.isEmpty { parts.append("\(field) in (\(values.map(quoted).joined(separator: ", ")))") }
        }
        add("labels", conditions.labels)
        if conditions.inOpenSprints { parts.append("sprint in openSprints()") }
        if let assignee = conditions.assignee, !assignee.isEmpty {
            parts.append("assignee = " + (assignee == "me" ? "currentUser()" : quoted(assignee)))
        }
        add("status", conditions.statuses); add("project", conditions.projects)
        return parts.joined(separator: " AND ")
    }
}
