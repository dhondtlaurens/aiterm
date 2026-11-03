import Foundation

/// A ticket's open merge requests in one repository, and a merge request's ticket: what New Review
/// fills one field from when the other is picked. Only this repository is searched — a review
/// starts from a repository, so a ticket whose request is elsewhere says none is here.
public enum TicketMergeRequests {
    /// What the lookup found, and whether it read every open request: past `pages` pages of 100 it
    /// stops, and then can claim neither that there is none nor that there is only one.
    public struct Found: Equatable, Sendable {
        public var requests: [MergeRequest], complete: Bool
        public init(requests: [MergeRequest], complete: Bool) { self.requests = requests; self.complete = complete }
    }

    /// How many pages of 100 open requests a Jira key is looked for in.
    public static let pages = 5

    /// The open requests of `repository` for `ticket`. A GitLab issue's are the ones GitLab says close
    /// or mention it. A Jira key's are read from the repository's open requests — the host's text
    /// search misses a key that is only in the branch (GitLab) or only in the description (GitHub) —
    /// and kept where the key is a whole token in the title, the description or the source branch.
    public static func requests(for ticket: JiraTicket, in repository: any HostRepository) async throws -> Found {
        if let number = ticket.issueNumber { return Found(requests: try await repository.openRequests(closingIssue: number), complete: true) }
        let read = try await repository.openRequests(pages: pages)
        var found = read.requests.filter { mentions(ticket.key, $0) }
        // Past the cap, the host's own search for the key still finds an older request by its title.
        if !read.complete {
            for request in try await repository.mergeRequests(search: ticket.key)
            where mentions(ticket.key, request) && !found.contains(where: { $0.iid == request.iid }) {
                found.append(request)
            }
        }
        return Found(requests: found, complete: read.complete)
    }

    /// Whether `key` is in the request's title, description or source branch as a whole token:
    /// `JVS-57` is not in `JVS-5744`, and `JVS-5744` is in `agent/JVS-5744-2`. Case-insensitive.
    public static func mentions(_ key: String, _ request: MergeRequest) -> Bool {
        [request.title, request.description ?? "", request.sourceBranch].contains { containsToken(key, in: $0) }
    }

    static func containsToken(_ key: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        return text.range(of: "(?<![A-Za-z0-9])\(escaped)(?![0-9])", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Which ticket a request is for, read off it: a GitLab issue it closes (`Closes #53` in its
    /// description, or a `53-…` branch, GitLab's own naming) when `issues` is set, else the first Jira
    /// key in its title, then its branch, then its description. The key is upper-cased, as Jira's are.
    public enum Reference: Equatable, Sendable {
        case jira(String), gitLabIssue(Int)
    }

    public static func reference(of request: MergeRequest, issues: Bool) -> Reference? {
        if issues, let number = closedIssue(of: request) { return .gitLabIssue(number) }
        for text in [request.title, request.sourceBranch, request.description ?? ""] {
            if let key = jiraKey(in: text) { return .jira(key) }
        }
        return nil
    }

    static func closedIssue(of request: MergeRequest) -> Int? {
        let pattern = #"(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|implement(?:s|ed)?)\s*:?\s+#(\d+)\b"#
        if let description = request.description, let match = firstGroup(pattern, in: description) { return Int(match) }
        let branch = request.sourceBranch.split(separator: "/").last.map(String.init) ?? request.sourceBranch
        return firstGroup(#"^(\d+)-"#, in: branch).flatMap { Int($0) }
    }

    static func jiraKey(in text: String) -> String? {
        firstGroup(#"(?<![A-Za-z0-9])([A-Za-z][A-Za-z0-9_]+-\d+)(?![0-9])"#, in: text).map { $0.uppercased() }
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
