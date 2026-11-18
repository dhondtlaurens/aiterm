import Foundation

/// A GitLab trigger's query in the merge request search bar's syntax, parsed into the GraphQL filters it runs as.
///
/// The role (`author:@me`, `assignee:@me` or `reviewer:@me`) picks the account's own list, and with it what
/// `review-state:` means; a Done query without one reads a project's merge requests. `threads:` tokens are
/// AiTerm's own and never reach GitLab. Every user value is sent as a GraphQL variable.
public struct GitLabQuery: Equatable, Sendable {
    public enum Role: String, Sendable {
        case author, assignee, reviewer
        /// The `currentUser` list the role reads.
        public var root: String {
            switch self {
            case .author: "authoredMergeRequests"
            case .assignee: "assignedMergeRequests"
            case .reviewer: "reviewRequestedMergeRequests"
            }
        }
    }

    /// Filter arguments by their GraphQL names. Usernames keep `@me` until a read names the account.
    public struct Arguments: Equatable, Sendable {
        public var authorUsername: String?
        public var assigneeUsername: String?, assigneeUsernames: [String]?, assigneeWildcardId: String?
        public var reviewerUsername: String?, reviewerWildcardId: String?
        public var reviewStates: [String]?, approvedBy: [String]?, draft: Bool?, labels: [String]?
        public var targetBranches: [String]?, sourceBranches: [String]?, milestoneTitle: String?
        public init() {}

        /// Each set argument with its GraphQL type and value.
        func fields(user: String) -> [(name: String, type: String, value: JSONValue)] {
            func name(_ value: String) -> JSONValue { .string(value == "@me" ? user : value) }
            func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
            var fields: [(name: String, type: String, value: JSONValue)] = []
            if let authorUsername { fields.append(("authorUsername", "String", name(authorUsername))) }
            if let assigneeUsername { fields.append(("assigneeUsername", "String", name(assigneeUsername))) }
            if let assigneeUsernames { fields.append(("assigneeUsernames", "[String!]", .array(assigneeUsernames.map(name)))) }
            if let assigneeWildcardId { fields.append(("assigneeWildcardId", "AssigneeWildcardId", .string(assigneeWildcardId))) }
            if let reviewerUsername { fields.append(("reviewerUsername", "String", name(reviewerUsername))) }
            if let reviewerWildcardId { fields.append(("reviewerWildcardId", "ReviewerWildcardId", .string(reviewerWildcardId))) }
            if let reviewStates { fields.append(("reviewStates", "[MergeRequestReviewState!]", strings(reviewStates))) }
            if let approvedBy { fields.append(("approvedBy", "[String!]", .array(approvedBy.map(name)))) }
            if let draft { fields.append(("draft", "Boolean", .bool(draft))) }
            if let labels { fields.append(("labels", "[String!]", strings(labels))) }
            if let targetBranches { fields.append(("targetBranches", "[String!]", strings(targetBranches))) }
            if let sourceBranches { fields.append(("sourceBranches", "[String!]", strings(sourceBranches))) }
            if let milestoneTitle { fields.append(("milestoneTitle", "String", .string(milestoneTitle))) }
            return fields
        }
    }

    /// One GraphQL request body.
    struct Request: Encodable, Equatable, Sendable {
        var query: String, variables: [String: JSONValue]
    }

    public var role: Role?
    public var arguments = Arguments()
    /// What GitLab's `not:` excludes.
    public var not = Arguments()
    /// Full paths, each read on its own; empty reads every project.
    public var projects: [String] = []
    public var state: String
    public var threads: [ThreadFilter] = []

    /// A Start query names the account in exactly one role.
    public static func start(_ text: String) throws -> GitLabQuery { try parse(text, start: true) }
    /// A Done query names one role or none.
    public static func done(_ text: String) throws -> GitLabQuery { try parse(text, start: false) }

    static let nodeFields = "iid title webUrl sourceBranch targetBranch description updatedAt draft state sourceProjectId targetProjectId detailedMergeStatus author{username} assignees{nodes{username}}"

    /// One page of the query: the role's `currentUser` list, narrowed to `project` when given, or without a role
    /// `project`'s merge requests. `iids` narrows it to those merge requests.
    func request(user: String, project: String?, iids: [Int] = [], cursor: String? = nil, nodes: String = nodeFields) -> Request {
        var declared: [String] = [], passed: [String] = [], variables: [String: JSONValue] = [:]
        func add(_ name: String, _ type: String, _ value: JSONValue, pass: Bool = true) {
            declared.append("$\(name):\(type)"); variables[name] = value
            if pass { passed.append("\(name):$\(name)") }
        }
        if role == nil { add("fullPath", "ID!", .string(project ?? ""), pass: false) }
        add("first", "Int!", 100)
        if let cursor { add("after", "String", .string(cursor)) }
        add("state", "MergeRequestState", .string(state))
        if role != nil, let project { add("projectPath", "String", .string(project)) }
        if !iids.isEmpty { add("iids", "[String!]", .array(iids.map { .string(String($0)) })) }
        for field in arguments.fields(user: user) { add(field.name, field.type, field.value) }
        let negated = not.fields(user: user)
        if !negated.isEmpty {
            add("not", "MergeRequestsResolverNegatedParams", .object(Dictionary(uniqueKeysWithValues: negated.map { ($0.name, $0.value) })))
        }
        let list = "(\(passed.joined(separator: ","))){pageInfo{hasNextPage endCursor} nodes{\(nodes)}}"
        let head = "query(\(declared.joined(separator: ",")))"
        if let role { return Request(query: head + "{currentUser{list:\(role.root)\(list)}}", variables: variables) }
        return Request(query: head + "{project(fullPath:$fullPath){list:mergeRequests\(list)}}", variables: variables)
    }

    // MARK: Parsing

    private static let keys: Set<String> = ["author", "assignee", "reviewer", "review-state", "approved-by", "draft", "label",
                                            "target-branch", "source-branch", "milestone", "project", "state", "threads"]
    private static let listKeys: Set<String> = ["review-state", "project"]
    private static let reviewStates = ["unreviewed", "review_started", "reviewed", "requested_changes", "approved", "unapproved"]

    private static func parse(_ text: String, start: Bool) throws -> GitLabQuery {
        let tokens = try QueryToken.split(text)
        var roles: [(role: Role, token: QueryToken)] = []
        for token in tokens where !token.negated {
            guard let role = token.key.flatMap(Role.init(rawValue:)), username(token.value) == "@me",
                  !roles.contains(where: { $0.role == role }) else { continue }
            roles.append((role, token))
        }
        if roles.count > 1 {
            throw QueryRefusal(token: roles[1].token.raw, message: "Name yourself in one role: keep one of \(sentence(roles.map(\.token.raw))).")
        }
        if start && roles.isEmpty {
            throw QueryRefusal(token: "", message: "Name yourself in one role: author:@me, assignee:@me or reviewer:@me.")
        }
        var query = GitLabQuery(role: roles.first?.role, state: start ? "opened" : "all")
        var stated: String?
        for token in tokens { try query.apply(token, stated: &stated) }
        if let stated { query.state = stated }
        return query
    }

    private mutating func apply(_ token: QueryToken, stated: inout String?) throws {
        guard let key = token.key, Self.keys.contains(key) else { throw QueryRefusal(token: token.raw, message: "Unknown filter \(token.raw).") }
        let value = token.value, lowered = token.value.lowercased()
        guard !value.isEmpty else { throw QueryRefusal(token: token.raw, message: "\(token.raw) needs a value.") }
        if !token.quoted, value.contains(","), !Self.listKeys.contains(key) {
            throw QueryRefusal(token: token.raw, message: "\(key) takes one value, not a list.")
        }
        func refuse(_ message: String) -> QueryRefusal { QueryRefusal(token: token.raw, message: message) }
        func set<Value: Equatable>(_ field: inout Value?, _ new: Value) throws {
            if let field, field != new { throw refuse("\(key) appears twice with different values; keep one.") }
            field = new
        }
        func append(_ field: inout [String]?, _ new: String) {
            if field?.contains(new) != true { field = (field ?? []) + [new] }
        }
        let cannotExclude = refuse("GitLab cannot exclude with \(token.raw); remove the -.")

        switch key {
        case "author", "assignee", "reviewer":
            let person = Role(rawValue: key)!, name = Self.username(value)
            // `-reviewer:any` is `reviewer:none` and the reverse; an author has no wildcard.
            let wildcard = person == .author ? nil
                : ["none": "NONE", "any": "ANY"][lowered].map { token.negated ? ($0 == "NONE" ? "ANY" : "NONE") : $0 }
            // The role's own list takes no positive argument for its own key: only `@me` again means anything there.
            if person == role, !token.negated || wildcard != nil {
                guard !token.negated, name == "@me" else { throw refuse("\(token.raw) cannot be combined with \(key):@me.") }
                return
            }
            switch (person, token.negated) {
            case (.author, false): try set(&arguments.authorUsername, name)
            case (.author, true): try set(&not.authorUsername, name)
            case (.assignee, _) where wildcard != nil: try set(&arguments.assigneeWildcardId, wildcard!)
            case (.assignee, false): try set(&arguments.assigneeUsername, name)
            case (.assignee, true): append(&not.assigneeUsernames, name)
            case (.reviewer, _) where wildcard != nil: try set(&arguments.reviewerWildcardId, wildcard!)
            case (.reviewer, false): try set(&arguments.reviewerUsername, name)
            case (.reviewer, true): try set(&not.reviewerUsername, name)
            }
        case "review-state":
            let states = try value.split(separator: ",", omittingEmptySubsequences: false).map { part in
                let state = part.trimmingCharacters(in: .whitespaces).lowercased()
                guard Self.reviewStates.contains(state) else {
                    throw refuse("review-state takes unreviewed, review_started, reviewed, requested_changes, approved or unapproved.")
                }
                return state.uppercased()
            }
            if token.negated { try set(&not.reviewStates, states) } else { try set(&arguments.reviewStates, states) }
        case "approved-by":
            if token.negated { append(&not.approvedBy, Self.username(value)) } else { append(&arguments.approvedBy, Self.username(value)) }
        case "draft":
            guard !token.negated else { throw refuse("Write draft:yes or draft:no rather than \(token.raw).") }
            guard let flag = ["yes": true, "no": false][lowered] else { throw refuse("draft takes yes or no.") }
            try set(&arguments.draft, flag)
        case "label":
            if token.negated { append(&not.labels, value) } else { append(&arguments.labels, value) }
        case "target-branch":
            if token.negated { append(&not.targetBranches, value) } else { append(&arguments.targetBranches, value) }
        case "source-branch":
            if token.negated { append(&not.sourceBranches, value) } else { append(&arguments.sourceBranches, value) }
        case "milestone":
            if token.negated { try set(&not.milestoneTitle, value) } else { try set(&arguments.milestoneTitle, value) }
        case "project":
            guard !token.negated else { throw cannotExclude }
            for part in value.split(separator: ",", omittingEmptySubsequences: false) {
                let path = part.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { throw refuse("project takes full paths such as group/project, separated by commas.") }
                if !projects.contains(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) { projects.append(path) }
            }
        case "state":
            guard !token.negated else { throw cannotExclude }
            guard ["opened", "merged", "closed", "all"].contains(lowered) else { throw refuse("state takes opened, merged, closed or all.") }
            try set(&stated, lowered)
        default:
            threads.append(try ThreadFilter(token))
        }
    }

    /// `@sam` is `sam`; `@me` (any case) stays `@me`.
    private static func username(_ value: String) -> String {
        if value.lowercased() == "@me" { return "@me" }
        return value.hasPrefix("@") ? String(value.dropFirst()) : value
    }

    private static func sentence(_ parts: [String]) -> String {
        parts.count < 2 ? parts.joined() : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }
}
