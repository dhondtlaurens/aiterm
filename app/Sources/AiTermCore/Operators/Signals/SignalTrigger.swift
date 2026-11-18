import Foundation

/// When a signal's task starts, or when its stage is done: the source it reads, the person's description and the
/// query that runs. JQL for Jira, GitLab's search-bar syntax for GitLab, GitHub's search syntax for GitHub.
public struct SignalTrigger: Codable, Equatable, Sendable {
    public enum Source: OpenStringEnum, Hashable, Sendable, CaseIterable {
        case jira, gitLab, gitHub
        case unknown(String)
        public static let allCases: [Self] = [.jira, .gitLab, .gitHub]
        static let knownCases: [Self] = allCases
        var savedName: String {
            switch self {
            case .jira: "jira"
            case .gitLab: "gitLab"
            case .gitHub: "gitHub"
            case .unknown(let value): value
            }
        }
    }

    /// Whom a Start query names the account as. It decides whether a task may merge.
    public enum Role: Equatable, Sendable { case author, assignee, reviewer }

    public var source: Source
    public var description: String
    public var query: String
    public init(source: Source, description: String = "", query: String) {
        self.source = source; self.description = description; self.query = query
    }

    /// Why the query cannot run as a Start (`start`) or Done trigger; nil when it can. Jira checks JQL itself.
    public func refusal(start: Bool) -> QueryRefusal? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return QueryRefusal(token: "", message: "Enter a query.") }
        do {
            switch source {
            case .jira: return nil
            case .gitLab: _ = try start ? GitLabQuery.start(text) : GitLabQuery.done(text)
            case .gitHub: _ = try start ? GitHubQuery.start(text) : GitHubQuery.done(text)
            case .unknown: return QueryRefusal(token: "", message: "This version of AiTerm cannot read this source.")
            }
        } catch let refusal as QueryRefusal {
            return refusal
        } catch {
            return QueryRefusal(token: "", message: error.localizedDescription)
        }
        return nil
    }

    public func isValid(start: Bool) -> Bool { refusal(start: start) == nil }

    /// The role a Start query names the account in; nil for Jira, for a GitHub query that names none, and for a query
    /// that cannot run.
    public var startRole: Role? {
        switch source {
        case .gitLab:
            switch (try? GitLabQuery.start(query))?.role {
            case .author?: return .author
            case .assignee?: return .assignee
            case .reviewer?: return .reviewer
            case nil: return nil
            }
        case .gitHub:
            guard let tokens = try? QueryToken.split(query) else { return nil }
            for token in tokens where !token.negated && token.value.lowercased() == "@me" {
                switch token.key {
                case "author": return .author
                case "assignee": return .assignee
                case "review-requested", "user-review-requested": return .reviewer
                default: continue
                }
            }
            return nil
        case .jira, .unknown: return nil
        }
    }

    /// Whether a signal starting from this trigger may merge when ready: its tickets' merge requests are the
    /// person's own, as are the merge requests it lists as their author or assignee.
    public var offersMerge: Bool {
        source == .jira || startRole == .author || startRole == .assignee
    }
}
