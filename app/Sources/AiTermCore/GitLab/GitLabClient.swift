import Foundation

public struct GitLabConfig: Equatable, Sendable {
    public var hostURL: URL, token: String
    public init(hostURL: URL, token: String) { self.hostURL = hostURL; self.token = token }
}

public enum GitLabError: Error, Equatable, LocalizedError {
    case unauthorized, network(String), badResponse(Int), decoding, projectNotFound(String)
    /// Nothing at the host answers GitLab's API — a mistyped host, or a web page in front of it.
    case noAPI(String)
    /// No GitLab user has this username.
    case noUser(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Check your GitLab access token in Settings › Integrations."
        case .network(let message): return "Couldn’t connect to GitLab. \(message)"
        case .badResponse(let status): return "GitLab returned an error (HTTP \(status)). Try again."
        case .decoding: return "Couldn’t read GitLab’s response. Try again."
        // A valid token that cannot see a project is a different instruction from a bad token.
        case .projectNotFound(let path): return "GitLab has no project at \(path), or your token cannot see it."
        case .noAPI(let host): return "GitLab’s API was not found at \(host). Check the host URL in Settings › Integrations."
        case .noUser(let username): return "GitLab has no user called \(username)."
        }
    }
}

public struct GitLabClient: Sendable {
    let config: GitLabConfig, session: URLSession
    public init(config: GitLabConfig, session: URLSession = .shared) { self.config = config; self.session = session }

    /// A GitLab project id is the namespaced path as **one** path segment, so every `/` inside it
    /// must be escaped, or `a/b/c` would split into three segments and 404 on every subgroup project.
    public static func encodedProject(_ path: String) -> String { HTTPJSON.pathSegment(path) }

    /// A project's API path, the base of every per-project request.
    static func projectPath(_ project: String) -> String { "/api/v4/projects/" + encodedProject(project) }

    /// The host as written in Settings, less its trailing slashes.
    static func base(_ host: URL) -> String {
        var base = host.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    public func testConnection() async throws -> String {
        struct User: Decodable { var username: String }
        return try await get(User.self, path: "/api/v4/user", notFound: .noAPI(Self.base(config.hostURL))).username
    }

    public func mergeRequests(project: String, search: String) async throws -> [MergeRequest] {
        let base = Self.requestsPath(project)
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)

        // Typing a merge request's number finds that merge request, rather than full-text
        // searching for the digits — the analogue of JiraClient's KEY-123 fast path.
        if let iid = Self.iid(text) {
            // GitLab answers 404 for a number no merge request has, as it does for a project the
            // token cannot see. Here the number is by far the likelier, and it reads as nothing found.
            do { return [try await get(MergeRequestPayload.self, path: base + "/\(iid)", notFound: .projectNotFound(project)).mergeRequest] }
            catch GitLabError.projectNotFound { return [] }
        }

        var query = [URLQueryItem(name: "state", value: "opened"),
                     URLQueryItem(name: "order_by", value: "updated_at"),
                     URLQueryItem(name: "per_page", value: "25")]
        if !text.isEmpty {
            query.append(URLQueryItem(name: "search", value: text))
            query.append(URLQueryItem(name: "in", value: "title,description"))
        }
        return try await get([Lenient<MergeRequestPayload>].self, path: base, query: query, notFound: .projectNotFound(project))
            .compactMap { $0.value?.mergeRequest }
    }

    // MARK: Issues — the tickets of a project that keeps them on GitLab

    /// The project's open issues, the most recently updated first, as tickets; `#55` or `55` is
    /// that issue, whatever its state. A project whose issues are off, or that the token cannot
    /// see, has none: GitLab answers those with 403 or 404, and a project without issues is the
    /// common case, not an error. A token GitLab no longer accepts (401) is one, and is thrown.
    public func issues(project: String, search: String) async throws -> [JiraTicket] {
        let base = Self.projectPath(project) + "/issues"
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let none = GitLabError.projectNotFound(project)
        let api = HostAPI(base: Self.base(config.hostURL), headers: ["PRIVATE-TOKEN": config.token, "Accept": "application/json"],
                          session: session, malformed: GitLabError.decoding,
                          mapping: { failure in
                              if case .status(403) = failure { return none }
                              return Self.error(for: failure, notFound: none)
                          })
        do {
            if let iid = Self.issueNumber(text) {
                return [try await api.get(IssuePayload.self, path: base + "/\(iid)", query: []).ticket(in: project)]
            }
            var query = [URLQueryItem(name: "state", value: "opened"),
                         URLQueryItem(name: "order_by", value: "updated_at"),
                         URLQueryItem(name: "per_page", value: "25")]
            if !text.isEmpty {
                query.append(URLQueryItem(name: "search", value: text))
                query.append(URLQueryItem(name: "in", value: "title,description"))
            }
            return try await api.get([Lenient<IssuePayload>].self, path: base, query: query)
                .compactMap { $0.value?.ticket(in: project) }
        } catch GitLabError.projectNotFound {
            return []
        }
    }

    /// The open merge requests in `project` that close issue `iid` or mention it, each once.
    public func openMergeRequests(project: String, closingIssue iid: Int) async throws -> [MergeRequest] {
        let base = Self.projectPath(project) + "/issues/\(iid)"
        var seen = Set<Int>(), found: [MergeRequest] = []
        for path in [base + "/closed_by", base + "/related_merge_requests"] {
            let page = try await get([Lenient<MergeRequestPayload>].self, path: path, notFound: .projectNotFound(project))
            for request in page.compactMap({ $0.value?.mergeRequest })
            where request.state == "opened" && Self.isIn(project, request) && seen.insert(request.iid).inserted {
                found.append(request)
            }
        }
        return found
    }

    /// Up to `pages` pages of the project's open merge requests, `perPage` at a time, the most
    /// recently updated first, and whether that was all of them: a page that came back short is
    /// the last one.
    public func openMergeRequests(project: String, perPage: Int = 100, pages: Int = 5) async throws -> (requests: [MergeRequest], complete: Bool) {
        var all: [MergeRequest] = []
        for page in 1...max(1, pages) {
            let query = [URLQueryItem(name: "state", value: "opened"), URLQueryItem(name: "order_by", value: "updated_at"),
                         URLQueryItem(name: "per_page", value: String(perPage)), URLQueryItem(name: "page", value: String(page))]
            let read = try await get([Lenient<MergeRequestPayload>].self, path: Self.requestsPath(project), query: query,
                                     notFound: .projectNotFound(project))
            all += read.compactMap { $0.value?.mergeRequest }
            if read.count < perPage { return (all, true) }
        }
        return (all, false)
    }

    /// `55` or `#55`.
    static func issueNumber(_ text: String) -> Int? {
        guard text.range(of: #"^#?\d+$"#, options: .regularExpression) != nil else { return nil }
        return Int(text.drop { $0 == "#" })
    }

    /// Whether `request` is one of `project`'s: an issue's related list can name another project's.
    static func isIn(_ project: String, _ request: MergeRequest) -> Bool {
        request.url.range(of: "/\(project)/-/merge_requests/", options: .caseInsensitive) != nil
    }

    /// GitLab's ISO 8601 times, with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// How many discussions one page of `reviewThreads` asks for, and how many pages it reads at
    /// most: a thousand threads, past which a merge request is not being reviewed by hand.
    static let discussionsPerPage = 100, discussionPages = 10
    /// How many pages `threads` reads before it gives up: past it the list is no answer.
    static let threadPagesRead = 50

    /// The merge request's review threads: its discussions that can be resolved, and how many of
    /// them are. Read a page at a time until one comes back short — GitLab's paging headers are not
    /// read, `HTTPJSON` hands back the body and the status only — and at most `discussionPages`.
    /// Read-only.
    public func reviewThreads(project: String, iid: Int) async throws -> ReviewThreads {
        let resolutions = try await readDiscussions(project: project, iid: iid, complete: false) { discussions in
            discussions.compactMap { $0.value?.resolution }
        }
        return ReviewThreads(resolutions: resolutions)
    }

    // MARK: Publishing — the only writes this client makes, for an operator's finish_task (spec §6)

    static func requestsPath(_ project: String) -> String {
        projectPath(project) + "/merge_requests"
    }

    /// The open merge request from `source`, if there is one: what a repeated finish_task finds
    /// instead of opening a second after a reply was lost. An entry that does not decode is no
    /// answer, not an absent request, and one from a fork's branch of the same name is not this one.
    public func openMergeRequest(project: String, source: String) async throws -> MergeRequest? {
        let query = [URLQueryItem(name: "state", value: "opened"), URLQueryItem(name: "source_branch", value: source)]
        return try await get([MergeRequestPayload].self, path: Self.requestsPath(project), query: query,
                             notFound: .projectNotFound(project))
            .first { $0.sourceProjectId == nil || $0.targetProjectId == nil || $0.sourceProjectId == $0.targetProjectId }?.mergeRequest
    }

    /// A merge request from `source` into `target`. A draft is GitLab's `Draft:` title prefix. The
    /// source branch is kept after a merge: deleting a branch is ask-first. Nothing here asks GitLab
    /// to merge, squash or rebase it: merging is `merge`, at the accepted commit.
    public func createMergeRequest(project: String, source: String, target: String, title: String,
                                   description: String, draft: Bool) async throws -> MergeRequest {
        struct Create: Encodable { var sourceBranch, targetBranch, title, description: String; var removeSourceBranch = false }
        let body = Create(sourceBranch: source, targetBranch: target, title: (draft ? "Draft: " : "") + Self.readyTitle(title),
                          description: description)
        return try await send(MergeRequestPayload.self, method: "POST", path: Self.requestsPath(project), body: body,
                              notFound: .projectNotFound(project)).mergeRequest
    }

    /// Whether GitLab would merge it now: its pipeline first — a merge end waits for green whatever
    /// the project requires — then whether it is a draft, then GitLab's `detailed_merge_status`.
    public func mergeReadiness(project: String, iid: Int) async throws -> MergeReadiness {
        try await get(MergeStatusPayload.self, path: Self.requestsPath(project) + "/\(iid)",
                      notFound: .projectNotFound(project)).readiness
    }

    /// The request as the Operator reads it (`MergeRequestState`): the same read as `mergeReadiness` and who approved it,
    /// asked together. `mergeable` is GitLab's `detailed_merge_status` as it says it, `state` when it gives none.
    public func mergeRequestState(project: String, iid: Int, url: String) async throws -> MergeRequestState {
        async let status = get(MergeStatusPayload.self, path: Self.requestsPath(project) + "/\(iid)", notFound: .projectNotFound(project))
        async let approved = approvals(project: project, iid: iid)
        let (read, by) = try await (status, approved)
        return MergeRequestState(iid: iid, url: url, draft: read.draft ?? false, pipeline: read.headPipeline?.status,
                                 mergeable: read.detailedMergeStatus ?? read.state ?? "unknown", approvedBy: by, head: read.sha)
    }

    /// Merges it at `sha`, the accepted commit: GitLab refuses (409) when the branch's head is any
    /// other. Only `sha` is sent — never auto-merge on a pipeline, squash or deleting the source
    /// branch. A refusal is `.blocked`, with GitLab's status; only a failure to ask throws. GitLab may
    /// answer before the merge has run (the request still open): that is `.waiting`, and `mergeReadiness`
    /// says when it has.
    public func merge(project: String, iid: Int, sha: String) async throws -> MergeReadiness {
        struct Merge: Encodable { var sha: String }
        do {
            let answer = try await send(MergeStatusPayload.self, method: "PUT", path: Self.requestsPath(project) + "/\(iid)/merge",
                                        body: Merge(sha: sha), notFound: .projectNotFound(project))
            switch answer.readiness {
            case .merged(let commit, let head, let target): return .merged(commit: commit.isEmpty ? sha : commit, head: head.isEmpty ? sha : head, target: target)
            case .ready, .waiting: return .waiting("GitLab has not finished merging it")
            case .blocked(let why): return .blocked(why)
            }
        } catch GitLabError.badResponse(409) {
            return .blocked("the branch moved past the accepted commit")
        } catch GitLabError.badResponse(let status) where [405, 406, 422].contains(status) {
            return .blocked("GitLab refused to merge it (HTTP \(status))")
        }
    }

    /// Points it at `target`: a stacked request, once its parent has merged.
    public func retarget(project: String, iid: Int, to target: String) async throws {
        struct Retarget: Encodable { var targetBranch: String }
        _ = try await send(MergeRequestPayload.self, method: "PUT", path: Self.requestsPath(project) + "/\(iid)",
                           body: Retarget(targetBranch: target), notFound: .projectNotFound(project))
    }

    // MARK: The Review slice (spec §5): people on the merge request, only for an operator whose broadcast allows it

    /// The prefixes GitLab reads as a draft, in any case: `Draft:`, `[Draft]`, `(Draft)`, and the older `WIP:`.
    static let draftPrefixes = ["draft:", "[draft]", "(draft)", "wip:", "[wip]"]

    /// `title` with GitLab's draft prefixes taken off its front.
    static func readyTitle(_ title: String) -> String {
        var rest = Substring(title)
        while true {
            let trimmed = rest.drop { $0 == " " }
            guard let prefix = draftPrefixes.first(where: { trimmed.lowercased().hasPrefix($0) }) else { return String(trimmed) }
            rest = trimmed.dropFirst(prefix.count)
        }
    }

    /// Takes it out of draft, which on GitLab is dropping the title's draft prefix. One that is not a
    /// draft is not written to.
    public func markReady(project: String, iid: Int, beforeWrite: @Sendable () async throws -> Void = {}) async throws {
        let path = Self.requestsPath(project) + "/\(iid)"
        let request = try await get(MergeRequestPayload.self, path: path, notFound: .projectNotFound(project))
        let ready = Self.readyTitle(request.title)
        guard ready != request.title || request.draft == true else { return }
        try await beforeWrite()
        struct Ready: Encodable { var title: String }
        _ = try await send(MergeRequestPayload.self, method: "PUT", path: path, body: Ready(title: ready), notFound: .projectNotFound(project))
    }

    /// Changes its title, description and assignee, each nil one left as it is; the assignee, looked up by its exact
    /// username, replaces any it has. A draft keeps its `Draft: ` prefix whatever title is given, since a title without it
    /// takes the request out of draft, and a draft prefix in `title` is dropped. `beforeWrite` gets the request as read
    /// before the write.
    public func updateMergeRequest(project: String, iid: Int, title: String?, description: String?, assignee: String?,
                                   beforeWrite: @Sendable (MergeRequest) async throws -> Void = { _ in }) async throws {
        let path = Self.requestsPath(project) + "/\(iid)"
        let request = try await get(MergeRequestPayload.self, path: path, notFound: .projectNotFound(project))
        var assigneeIds: [Int]?
        if let assignee { assigneeIds = [try await userId(assignee)] }
        try await beforeWrite(request.mergeRequest)
        struct Edit: Encodable { var title, description: String?; var assigneeIds: [Int]? }
        let draft = request.draft == true || Self.readyTitle(request.title) != request.title
        let edit = Edit(title: title.map { (draft ? "Draft: " : "") + Self.readyTitle($0) }, description: description, assigneeIds: assigneeIds)
        _ = try await send(MergeRequestPayload.self, method: "PUT", path: path, body: edit, notFound: .projectNotFound(project))
    }

    /// The id of the user with exactly `username`; `noUser` when there is none.
    private func userId(_ username: String) async throws -> Int {
        struct User: Decodable { var id: Int, username: String }
        let found = try await get([User].self, path: "/api/v4/users", query: [URLQueryItem(name: "username", value: username)],
                                  notFound: .noAPI(Self.base(config.hostURL)))
        guard let user = found.first(where: { $0.username.lowercased() == username.lowercased() }) else { throw GitLabError.noUser(username) }
        return user.id
    }

    /// Adds `usernames` to its reviewers, each looked up by its exact username; the reviewers it has stay.
    /// Nothing is written when every one of them reviews it already.
    public func assignReviewers(project: String, iid: Int, usernames: [String],
                                beforeWrite: @Sendable () async throws -> Void = {}) async throws {
        let ids = try await JiraClient.inOrder(usernames) { try await userId($0) }
        struct Reviewers: Decodable { struct Reviewer: Decodable { var id: Int }; var reviewers: [Reviewer]? }
        let path = Self.requestsPath(project) + "/\(iid)"
        let current = (try await get(Reviewers.self, path: path, notFound: .projectNotFound(project)).reviewers ?? []).map(\.id)
        let all = current + ids.filter { !current.contains($0) }
        guard all.count > current.count else { return }
        try await beforeWrite()
        struct Assign: Encodable { var reviewerIds: [Int] }
        _ = try await send(MergeRequestPayload.self, method: "PUT", path: path, body: Assign(reviewerIds: all), notFound: .projectNotFound(project))
    }

    /// Its review threads: each discussion that can be resolved, with its id, whether it is, and its last
    /// note that is not GitLab's own. Read a page at a time until an **empty** one (a short page proves nothing, as
    /// for protected branches): `threadPagesRead` pages without reaching it, or a discussion that does not decode, or
    /// a thread without an id, throws `IncompleteRead`, so nothing is decided on part of them.
    public func threads(project: String, iid: Int) async throws -> [ReviewThread] {
        try await readDiscussions(project: project, iid: iid, complete: true) { discussions in
            try discussions.compactMap { entry in
                guard let discussion = entry.value else { throw IncompleteRead("review threads") }
                guard discussion.resolution != nil else { return nil }
                guard let thread = discussion.thread else { throw IncompleteRead("review threads") }
                return thread
            }
        }
    }

    /// Badges stop on a short page or at their bound; publication requires the terminal empty page.
    /// Project binding, requests and per-page validation are shared without making a partial read complete.
    private func readDiscussions<Item>(project: String, iid: Int, complete: Bool,
                                       items: ([Lenient<DiscussionPayload>]) throws -> [Item]) async throws -> [Item] {
        var result: [Item] = []
        for page in 1...(complete ? Self.threadPagesRead : Self.discussionPages) {
            let discussions = try await get([Lenient<DiscussionPayload>].self, path: Self.requestsPath(project) + "/\(iid)/discussions",
                query: [URLQueryItem(name: "per_page", value: String(Self.discussionsPerPage)), URLQueryItem(name: "page", value: String(page))],
                notFound: .projectNotFound(project))
            if discussions.isEmpty { return result }
            result += try items(discussions)
            if !complete && discussions.count < Self.discussionsPerPage { return result }
        }
        if complete { throw IncompleteRead("review threads") }
        return result
    }

    /// A reply in the discussion `discussion`.
    public func reply(project: String, iid: Int, discussion: String, body: String) async throws {
        struct Note: Encodable { var body: String }
        struct Posted: Decodable { var id: Int }
        _ = try await send(Posted.self, method: "POST", path: Self.requestsPath(project) + "/\(iid)/discussions/\(Self.encodedProject(discussion))/notes",
                           body: Note(body: body), notFound: .projectNotFound(project))
    }

    /// The discussion `discussion` whole: the file and line its first note is on, when it is on the diff, and every note
    /// that is not GitLab's own, oldest first.
    public func threadDetail(project: String, iid: Int, discussion: String) async throws -> ReviewThreadDetail {
        struct Discussion: Decodable {
            struct Position: Decodable { var newPath: String?, newLine: Int?, oldPath: String?, oldLine: Int? }
            struct Note: Decodable {
                struct Author: Decodable { var username: String? }
                var body: String?, author: Author?, system: Bool?, position: Position?
            }
            var id: String, notes: [Note]?
        }
        let read = try await get(Discussion.self, path: Self.requestsPath(project) + "/\(iid)/discussions/\(Self.encodedProject(discussion))",
                                 notFound: .projectNotFound(project))
        let notes = (read.notes ?? []).filter { $0.system != true }
        let position = notes.first?.position
        return ReviewThreadDetail(id: read.id, path: position?.newPath ?? position?.oldPath, line: position?.newLine ?? position?.oldLine,
                            notes: notes.map { ReviewThreadDetail.Note(author: $0.author?.username, body: $0.body ?? "") })
    }

    /// Resolves the discussion `discussion`; GitLab leaves one resolved already as it is.
    public func resolve(project: String, iid: Int, discussion: String) async throws {
        struct Resolve: Encodable { var resolved = true }
        struct Resolved: Decodable { var id: String? }
        _ = try await send(Resolved.self, method: "PUT", path: Self.requestsPath(project) + "/\(iid)/discussions/\(Self.encodedProject(discussion))",
                           body: Resolve(), notFound: .projectNotFound(project))
    }

    /// Retries its head pipeline once it failed: GitLab reruns that pipeline's failed jobs. Any other status, or none, is
    /// `.notFailed` with nothing written. `beforeWrite` gets the request as read, right before the retry.
    public func retryPipeline(project: String, iid: Int, beforeWrite: @Sendable (MergeRequest) async throws -> Void = { _ in }) async throws -> PipelineRetry {
        let read = try await get(RequestWithPipeline.self, path: Self.requestsPath(project) + "/\(iid)", notFound: .projectNotFound(project))
        guard let pipeline = read.headPipeline else { return .notFailed("it has no pipeline") }
        guard pipeline.status == "failed", let id = pipeline.id else {
            return .notFailed("its pipeline is \((pipeline.status ?? "unknown").replacingOccurrences(of: "_", with: " "))")
        }
        try await beforeWrite(read.request.mergeRequest)
        struct Nothing: Encodable {}
        struct Retried: Decodable { var id: Int? }
        _ = try await send(Retried.self, method: "POST", path: Self.projectPath(project) + "/pipelines/\(id)/retry", body: Nothing(),
                           notFound: .projectNotFound(project))
        return .retried("pipeline \(id)")
    }

    /// The project's members who match `query`, by username or name: who may review in it.
    public func findUsers(project: String, query: String) async throws -> [HostUser] {
        struct User: Decodable { var username: String, name: String? }
        let items = [URLQueryItem(name: "search", value: query), URLQueryItem(name: "per_page", value: "20")]
        return try await get([Lenient<User>].self, path: Self.projectPath(project) + "/users", query: items,
                             notFound: .projectNotFound(project))
            .compactMap { $0.value.map { HostUser(username: $0.username, name: $0.name) } }
    }

    /// Who approved it, by username.
    public func approvals(project: String, iid: Int) async throws -> [String] {
        struct Approvals: Decodable {
            struct Approval: Decodable { struct User: Decodable { var username: String }; var user: User? }
            var approvedBy: [Approval]?
        }
        return (try await get(Approvals.self, path: Self.requestsPath(project) + "/\(iid)/approvals", notFound: .projectNotFound(project))
            .approvedBy ?? []).compactMap { $0.user?.username }
    }

    /// How many pages of 100 protected-branch rules a listing reads before it gives up.
    public static let protectedPages = 20

    /// The branch-name patterns `project` protects itself — exact names and `*` wildcards — every page of
    /// them (see `protectedRules`). Group-level rules are `branchProtection`'s to add.
    public func protectedBranches(project: String) async throws -> [String] {
        try await protectedRules(path: Self.projectPath(project) + "/protected_branches",
                                 notFound: .projectNotFound(project), noneIfMissing: false)
    }

    /// Every rule of a protected-branches listing, a page of 100 at a time until an **empty** page: a short
    /// page proves nothing (a proxy or a newer GitLab may cap `per_page` lower, and offset paging can shift a
    /// rule between pages). The `protectedPages` pages spent without reaching one is no answer, not a partial
    /// one, and a rule that does not decode fails the whole list instead of being dropped. A 404 on the first
    /// page is "no rules" when `noneIfMissing` (a group listing); anywhere else it is an error.
    private func protectedRules(path: String, notFound: GitLabError, noneIfMissing: Bool) async throws -> [String] {
        struct Protected: Decodable { var name: String }
        return try await HTTPJSON.pagesUntilEmpty(limit: Self.protectedPages, exhausted: ProtectionUnknown.tooManyRules(Self.protectedPages * 100)) { page in
            do {
                return try await get([Protected].self, path: path,
                    query: [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))], notFound: notFound)
            } catch GitLabError.projectNotFound where noneIfMissing && page == 1 { return [] }
        } items: { $0.map(\.name) }
    }

    /// The rules of the top-level group `group`, as GitLab's group-level protected branches (Premium and up).
    /// A group without any answers 404 and has none; anything else that goes wrong is `ProtectionUnknown`,
    /// which includes a host that answers 403 for the listing: it refuses every publish rather than guess.
    private func groupProtectedBranches(group: String) async throws -> [String] {
        do {
            return try await protectedRules(path: "/api/v4/groups/" + Self.encodedProject(group) + "/protected_branches",
                                            notFound: .projectNotFound(group), noneIfMissing: true)
        } catch let error as GitLabError {
            let why = (error.errorDescription ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            throw ProtectionUnknown.unreadable("AiTerm could not read the protected branches of the GitLab group \(group): \(why)")
        }
    }

    /// The top-level group `project` lives under, from its namespace: nil in a user's namespace. A namespace
    /// GitLab does not describe is no answer.
    private func topLevelGroup(of project: String) async throws -> String? {
        struct Owner: Decodable {
            struct Namespace: Decodable { var kind: String?, fullPath: String? }
            var namespace: Namespace?
        }
        let owner = try await get(Owner.self, path: Self.projectPath(project), notFound: .projectNotFound(project))
        switch owner.namespace?.kind {
        case "user": return nil
        case "group":
            if let root = owner.namespace?.fullPath?.split(separator: "/").first { return String(root) }
        default: break
        }
        throw ProtectionUnknown.unreadable("GitLab did not say which namespace \(project) is in")
    }

    /// Whether GitLab protects `branch` in `project`, asked before AiTerm pushes it, whether or not GitLab
    /// has the branch yet. Three sources, any of which covers it: the project's protected branches, its
    /// top-level group's (read through the project's namespace), and — when the branch already exists on
    /// GitLab, which then computes it from every effective rule — the branch's own `protected` flag. Rules
    /// match by name or wildcard, case-sensitively, as GitLab compares names.
    /// A failure to ask, a rule list that cannot be read whole, and a rule AiTerm cannot evaluate (unless
    /// another rule covers the branch anyway) throw: nothing is pushed then, never "unprotected".
    public func branchProtection(project: String, branch: String) async throws -> BranchProtection {
        let name = branch.hasPrefix("refs/heads/") ? String(branch.dropFirst("refs/heads/".count)) : branch
        guard !name.isEmpty else { throw ProtectionUnknown.unreadable("There is no branch name to check") }
        let group = try await topLevelGroup(of: project)
        var unreadable: ProtectionUnknown?
        func covering(_ rules: [String]) -> String? {
            for rule in rules {
                do { if try BranchProtection.evaluate(rule, name, starCrossesSlash: true) { return rule } }
                catch let error as ProtectionUnknown { unreadable = unreadable ?? error } catch {}
            }
            return nil
        }
        func said(_ rule: String, of owner: String) -> BranchProtection {
            .protected(rule == name ? "\(owner) protects it" : "\(owner) protects \(rule)")
        }
        if let rule = covering(try await protectedBranches(project: project)) { return said(rule, of: "GitLab") }
        if let group, let rule = covering(try await groupProtectedBranches(group: group)) { return said(rule, of: "GitLab group \(group)") }
        struct Existing: Decodable { var `protected`: Bool }
        do {
            let path = Self.projectPath(project) + "/repository/branches/" + Self.encodedProject(name)
            if try await get(Existing.self, path: path, notFound: .projectNotFound(project)).protected { return .protected("GitLab protects it") }
        } catch GitLabError.projectNotFound {}   // the project was just read: this is a branch GitLab does not have yet
        if let unreadable { throw unreadable }
        return .unprotected
    }

    private func send<Body: Encodable, Payload: Decodable>(_ type: Payload.Type, method: String, path: String, body: Body,
                                                           notFound: GitLabError) async throws -> Payload {
        try await api(notFound).send(type, method: method, path: path, body: body, encoder: .snakeCase)
    }

    static func iid(_ text: String) -> Int? {
        guard text.range(of: #"^!?\d+$"#, options: .regularExpression) != nil else { return nil }
        return Int(text.hasPrefix("!") ? String(text.dropFirst()) : text)
    }

    /// `notFound` is what a 404 means for this `path`.
    private func get<Payload: Decodable>(_ type: Payload.Type, path: String, query: [URLQueryItem] = [],
                                         notFound: GitLabError) async throws -> Payload {
        try await api(notFound).get(type, path: path, query: query)
    }

    private func api(_ notFound: GitLabError) -> HostAPI {
        HostAPI(base: Self.base(config.hostURL), headers: ["PRIVATE-TOKEN": config.token, "Accept": "application/json"], session: session, malformed: GitLabError.decoding,
                mapping: { Self.error(for: $0, notFound: notFound) })
    }

    static func error(for failure: HTTPJSON.Failure, notFound: GitLabError) -> GitLabError {
        switch failure {
        case .transport(let error): return .network(error.localizedDescription)
        case .undecodable: return .decoding
        case .status(401), .status(403): return .unauthorized
        case .status(404): return notFound
        case .status(let status): return .badResponse(status)
        }
    }
}

/// The fields of a merge request the picker shows.
private struct MergeRequestPayload: Decodable {
    struct Author: Decodable { var name: String? }
    var iid: Int, title: String, sourceBranch: String, targetBranch: String, webUrl: String
    var author: Author?, state: String?, draft: Bool?, description: String?
    /// Where the branch lives and where the request goes; they differ for a request from a fork.
    var sourceProjectId: Int?, targetProjectId: Int?

    var mergeRequest: MergeRequest {
        MergeRequest(iid: iid, title: title, sourceBranch: sourceBranch, targetBranch: targetBranch,
                     author: author?.name, state: state ?? "opened", draft: draft ?? false, url: webUrl,
                     forkHead: sourceProjectId != nil && targetProjectId != nil && sourceProjectId != targetProjectId
                         ? "project \(sourceProjectId!):\(sourceBranch)" : nil,
                     description: description)
    }
}

/// A merge request with its head pipeline, read in one answer: what `retryPipeline` decides on.
private struct RequestWithPipeline: Decodable {
    struct Pipeline: Decodable { var id: Int?, status: String? }
    private struct Head: Decodable { var headPipeline: Pipeline? }
    let request: MergeRequestPayload, headPipeline: Pipeline?
    init(from decoder: Decoder) throws {
        request = try MergeRequestPayload(from: decoder)
        headPipeline = try Head(from: decoder).headPipeline
    }
}

/// The fields of an issue the ticket picker shows and a task's prompt carries.
private struct IssuePayload: Decodable {
    /// The picker's lane column: the first label that says what kind of work it is — GitLab sorts
    /// labels by name, so `priority::medium` comes before `refactor` — else the first scoped one.
    static func lane(of labels: [String]) -> String? { labels.first { !$0.contains("::") } ?? labels.first }

    var iid: Int, title: String, webUrl: String
    var description: String?, labels: [String]?, updatedAt: String?

    func ticket(in project: String) -> JiraTicket {
        let labels = labels ?? []
        let text = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return JiraTicket(key: "#\(iid)", summary: title, description: text?.isEmpty == false ? text : nil,
                          issueType: labels.isEmpty ? nil : labels.joined(separator: " "), status: Self.lane(of: labels), url: webUrl,
                          source: .gitLab(project: project), updated: updatedAt.flatMap(GitLabClient.date))
    }
}

/// The fields of a discussion `reviewThreads` counts and `threads` reads.
private struct DiscussionPayload: Decodable {
    struct Author: Decodable { var username: String? }
    struct Note: Decodable { var resolvable: Bool?, resolved: Bool?, body: String?, author: Author?, system: Bool? }
    var id: String?
    var notes: [Note]?

    /// The discussion as a thread, when it is one and has an id.
    var thread: ReviewThread? {
        guard let id, let resolved = resolution else { return nil }
        let last = (notes ?? []).last { $0.system != true }
        return ReviewThread(id: id, resolved: resolved, lastAuthor: last?.author?.username, lastBody: last?.body ?? "")
    }

    /// Whether the discussion is resolved — every note in it that can be resolved, is — or nil
    /// when none can be: a plain comment, a system note. Those are not threads.
    var resolution: Bool? {
        let resolvable = (notes ?? []).filter { $0.resolvable == true }
        return resolvable.isEmpty ? nil : resolvable.allSatisfy { $0.resolved == true }
    }
}

/// The fields of a merge request that say whether it can merge now.
private struct MergeStatusPayload: Decodable {
    struct Pipeline: Decodable { var status: String? }
    var state: String?, detailedMergeStatus: String?, sha: String?, draft: Bool?, hasConflicts: Bool?
    var targetBranch: String?
    var mergeCommitSha: String?, squashCommitSha: String?, headPipeline: Pipeline?

    var readiness: MergeReadiness {
        if state == "merged" { return .merged(commit: mergeCommitSha ?? squashCommitSha ?? sha ?? "", head: sha ?? "", target: targetBranch) }
        guard state == "opened" else { return .blocked("the merge request is \(state ?? "not open")") }
        switch headPipeline?.status ?? "" {
        case "failed": return .blocked("its pipeline failed")
        case "canceled": return .blocked("its pipeline was canceled")
        case "created", "waiting_for_resource", "preparing", "waiting_for_callback", "pending", "running", "scheduled", "canceling":
            return .waiting("its pipeline is running")
        // A pipeline that stopped at a manual job or never ran has not passed, whatever the project requires.
        case "manual": return .blocked("the pipeline waits for a manual job")
        // Many CIs skip the pipeline while it is a draft: no failure then, so the draft is all that stops it.
        case "skipped" where draft == true: break
        case "skipped": return .blocked("the pipeline was skipped")
        case "", "success": break   // green, or no pipeline at all
        case let other: return .waiting("its pipeline is \(other.replacingOccurrences(of: "_", with: " "))")
        }
        // A draft is said once its pipeline has: what else stops it comes first.
        if draft == true { return hasConflicts == true ? .blocked("it has conflicts") : .blocked(MergeReadiness.draftReason) }
        guard let status = detailedMergeStatus else { return .waiting("GitLab is checking it") }
        switch status {
        case "mergeable": return sha.map { .ready(head: $0) } ?? .waiting("GitLab is checking it")
        case "checking", "unchecked", "preparing", "approvals_syncing", "ci_still_running": return .waiting("GitLab is checking it")
        case "ci_must_pass": return .waiting("its pipeline must pass")
        case "not_approved": return .waiting("it needs an approval")
        case "conflict": return .blocked("it has conflicts")
        case "need_rebase": return .blocked("it needs a rebase")
        case "draft_status": return .blocked(MergeReadiness.draftReason)
        case "discussions_not_resolved": return .blocked("it has unresolved threads")
        default: return .blocked("GitLab says " + status.replacingOccurrences(of: "_", with: " "))
        }
    }
}
