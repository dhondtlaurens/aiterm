import Foundation

/// When a signal's task starts, or when its stage is done: the source it reads, the person's description and the
/// query that runs. JQL for Jira, GitLab's search-bar syntax for GitLab, GitHub's search syntax for GitHub, a cron
/// expression for a schedule. An Operator Done has no query: its description is guidance for the Operator and the Oracle.
public struct SignalTrigger: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Hashable, Sendable, CaseIterable {
        case jira, gitLab, gitHub
        /// A Start only: the query is a cron expression, each firing a new task in `project`.
        case schedule
        /// A Done only: the Operator judges the stage done and the Oracle confirms it.
        case `operator`
        /// A Done only, "You decide": no watch, the person ends the task. Saved as "person"; not `.none`, which an
        /// optional chain would read as `Optional.none`.
        case person
        /// The sources that read items from a host: the Reads row.
        public static let itemSources: [Self] = [.jira, .gitLab, .gitHub]
        /// Whether it reads items from a host.
        public var readsItems: Bool { Self.itemSources.contains(self) }
    }

    /// Whom a Start query names the account as. It decides whether a task may merge.
    public enum Role: Equatable, Sendable { case author, assignee, reviewer }

    public var source: Source
    public var description: String
    public var query: String
    /// A schedule's project: where each run starts its task. Nil for every other source.
    public var project: UUID?
    public init(source: Source, description: String = "", query: String, project: UUID? = nil) {
        self.source = source; self.description = description; self.query = query; self.project = project
    }

    /// A schedule's cron, nil when it is not one or does not parse.
    public var cron: Cron? { source == .schedule ? try? Cron(query) : nil }

    /// Why the query cannot run as a Start (`start`) or Done trigger; nil when it can. Jira checks JQL itself.
    public func refusal(start: Bool) -> QueryRefusal? {
        switch source {
        case .operator:
            return start ? QueryRefusal(token: "", message: "The Operator decides only when a signal is done.") : nil
        case .person:
            return start ? QueryRefusal(token: "", message: "You decide only when a signal is done.") : nil
        case .schedule:
            guard start else { return QueryRefusal(token: "", message: "A schedule can only start a signal.") }
            do { _ = try Cron(query) } catch { return error }
            return project == nil ? QueryRefusal(token: "", message: "Choose a project for its runs.") : nil
        default: break
        }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return QueryRefusal(token: "", message: "Enter a query.") }
        do {
            switch source {
            case .jira: return nil
            case .gitLab: _ = try start ? GitLabQuery.start(text) : GitLabQuery.done(text)
            case .gitHub: _ = try start ? GitHubQuery.start(text) : GitHubQuery.done(text)
            case .schedule, .operator, .person: return nil
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
        case .jira, .schedule, .operator, .person: return nil
        }
    }

    /// Whether a signal starting from this trigger may merge when ready: its tickets' merge requests are the
    /// person's own, as are the merge requests it lists as their author or assignee, and those its runs open.
    public var offersMerge: Bool {
        source == .jira || source == .schedule || startRole == .author || startRole == .assignee
    }
}
