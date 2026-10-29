import Foundation

public struct GitHubConfig: Equatable, Sendable {
    public var token: String
    public init(token: String) { self.token = token }
}

public enum GitHubError: Error, Equatable, LocalizedError {
    case unauthorized, forbidden, network(String), badResponse(Int), decoding, repoNotFound(String)
    /// GraphQL answered with an error of its own, in GitHub's words.
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Check your GitHub access token in Settings › Integrations."
        // GitHub answers both a token without access to the repository and a spent rate limit with 403.
        case .forbidden: return "GitHub refused: the token can’t read this repository, or the rate limit was reached."
        case .network(let message): return "Couldn’t connect to GitHub. \(message)"
        case .badResponse(let status): return "GitHub returned an error (HTTP \(status)). Try again."
        case .decoding: return "Couldn’t read GitHub’s response. Try again."
        case .repoNotFound(let path): return "GitHub has no repository at \(path), or your token cannot see it."
        case .refused(let message): return "GitHub refused it: \(message)"
        }
    }
}

/// github.com's REST API with the token from Settings. `Authorization` is one of
/// `HTTPJSON.credentialHeaders`, so the token never follows a redirect off `api.github.com`.
public struct GitHubClient: Sendable {
    let config: GitHubConfig, session: URLSession
    public init(config: GitHubConfig, session: URLSession = .shared) { self.config = config; self.session = session }

    static let api = "https://api.github.com"
    /// How many open pull requests one search reads, and how many it shows.
    static let readLimit = 100, shownLimit = 25

    public func testConnection() async throws -> String {
        struct User: Decodable { var login: String }
        return try await get(User.self, path: "/user", notFound: .badResponse(404)).login
    }

    /// GitHub's search API does not return a pull request's branch, so the newest open ones are
    /// read and filtered here, by title, branch or author. Typing a number fetches that one.
    public func pullRequests(repo: String, search: String) async throws -> [MergeRequest] {
        let base = "/repos/\(repo)/pulls"
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Self.number(text) {
            do { return [try await get(PullPayload.self, path: base + "/\(number)", notFound: .repoNotFound(repo)).mergeRequest] }
            catch GitHubError.repoNotFound { return [] }
        }
        let query = [URLQueryItem(name: "state", value: "open"), URLQueryItem(name: "sort", value: "updated"),
                     URLQueryItem(name: "direction", value: "desc"), URLQueryItem(name: "per_page", value: String(Self.readLimit))]
        let open = try await get([Lenient<PullPayload>].self, path: base, query: query, notFound: .repoNotFound(repo))
            .compactMap { $0.value?.mergeRequest }
        let matching = text.isEmpty ? open : open.filter { pull in
            [pull.title, pull.sourceBranch, pull.author ?? ""].contains { $0.range(of: text, options: .caseInsensitive) != nil }
        }
        return Array(matching.prefix(Self.shownLimit))
    }

    /// `87`, `#87`, or GitLab's `!87` from habit.
    static func number(_ text: String) -> Int? {
        guard text.range(of: #"^[#!]?\d+$"#, options: .regularExpression) != nil else { return nil }
        return Int(text.drop { $0 == "#" || $0 == "!" })
    }

    /// How many review threads one page of `reviewThreads` asks for, and how many pages it reads
    /// at most.
    static let threadsPerPage = 100, threadPages = 10
    /// How many pages `threads` and `approvals` read before they give up: past it the list is no answer.
    static let threadPagesRead = 50

    /// One query, never a mutation: the threads of a pull request and whether each is resolved.
    static let threadsQuery = """
        query($owner: String!, $name: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              reviewThreads(first: \(threadsPerPage), after: $after) { pageInfo { hasNextPage endCursor } nodes { isResolved } }
            }
          }
        }
        """

    /// The pull request's review threads, and how many are resolved. REST has none, so this is
    /// GraphQL's `reviewThreads`, read with the same token — a fine-grained token needs read access
    /// to pull requests, as the search already does; a classic one, `repo` for a private
    /// repository. GraphQL answers a repository or pull request it cannot see with 200, a null and
    /// an error, which is thrown here rather than read as no threads.
    public func reviewThreads(repo: String, number: Int) async throws -> ReviewThreads {
        let resolutions = try await readThreads(ThreadResolution.self, repo: repo, number: number, complete: false,
            answer: { (answer: GraphQLAnswer<ThreadsPayload<ThreadResolution>, ThreadProblem>) in
                guard let data = answer.data, data.repository?.pullRequest != nil else {
                    throw answer.errors?.contains { $0.type == "FORBIDDEN" } == true ? GitHubError.forbidden : GitHubError.repoNotFound(repo)
                }
                return data
            }, items: { $0.compactMap { $0.value?.isResolved } })
        return ReviewThreads(resolutions: resolutions)
    }

    // MARK: Publishing — the only writes this client makes, for an operator's finish_task (spec §6).
    // A fine-grained token needs write access to pull requests (open, retarget) and contents (merge).

    /// `owner/name` as its two parts; nil for anything else.
    static func ownerAndName(_ repo: String) -> (owner: String, name: String)? {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// How many pages of 100 a listing reads before it gives up: check runs, statuses, rules.
    static let listedPages = 20

    /// The open pull request from `source` in `repo` itself, if there is one: what a repeated
    /// finish_task finds instead of opening a second after a reply was lost. An entry that does not
    /// decode is no answer, not an absent request, and one from a fork's branch of the same name is
    /// not this one.
    public func openPullRequest(repo: String, source: String) async throws -> MergeRequest? {
        guard let (owner, _) = Self.ownerAndName(repo) else { throw GitHubError.repoNotFound(repo) }
        let query = [URLQueryItem(name: "state", value: "open"), URLQueryItem(name: "head", value: "\(owner):\(source)"),
                     URLQueryItem(name: "per_page", value: "100")]
        guard let encoded = HTTPJSON.url(Self.api + "/repos/\(repo)/pulls", query: query) else { throw GitHubError.decoding }
        return try await HTTPJSON.decode([PullPayload].self, HTTPJSON.request(encoded, headers: headers), session: session) {
            Self.error(for: $0, notFound: .repoNotFound(repo))
        }.value
            .map(\.mergeRequest).first { $0.sourceBranch == source && $0.forkHead == nil }
    }

    /// A pull request from `source` into `target`, a draft or not. The branch is never deleted
    /// afterwards and auto-merge is never enabled: merging is `merge`, at the accepted commit.
    public func createPullRequest(repo: String, source: String, target: String, title: String, body: String,
                                  draft: Bool) async throws -> MergeRequest {
        struct Create: Encodable { var title, head, base, body: String; var draft: Bool }
        return try await send(PullPayload.self, method: "POST", path: "/repos/\(repo)/pulls",
                              body: Create(title: title, head: source, base: target, body: body, draft: draft),
                              notFound: .repoNotFound(repo)).mergeRequest
    }

    /// Whether GitHub would merge it now (a head with no check runs or statuses at all follows `mergeable_state`
    /// alone, so a caller debounces a ready answer): merged or closed first, then every check run and
    /// commit status on its head, then a draft — a merge end waits for green whatever branch protection requires; a
    /// skipped, neutral or action-required check is not green and a pending one is not yet — then
    /// `mergeable` and `mergeable_state`. Only `clean` and `has_hooks` with `mergeable` true is ready.
    public func mergeReadiness(repo: String, number: Int) async throws -> MergeReadiness {
        let pull = try await get(PullStatusPayload.self, path: "/repos/\(repo)/pulls/\(number)", notFound: .repoNotFound(repo))
        if pull.merged == true { return .merged(commit: pull.mergeCommitSha ?? pull.head.sha, head: pull.head.sha, target: pull.base?.ref) }
        guard pull.state == "open" else { return .blocked("the pull request is closed") }
        let commit = "/repos/\(repo)/commits/\(pull.head.sha)"
        async let readRuns = listed(CheckRunsPayload.self, path: commit + "/check-runs", repo: repo)
        async let readStatuses = listed(CombinedStatusPayload.self, path: commit + "/status", repo: repo)
        guard let runs = try await readRuns, let statuses = try await readStatuses else {
            return .waiting("GitHub has not listed all its checks")
        }
        var running = false
        for run in runs {
            guard run.status == "completed" else { running = true; continue }
            switch run.conclusion ?? "" {
            case "success": continue
            case "failure", "timed_out", "startup_failure": return .blocked("its check \(run.name) failed")
            case "cancelled": return .blocked("its check \(run.name) was cancelled")
            case "action_required": return .blocked("its check \(run.name) needs someone to act")
            // Many CIs skip their checks while it is a draft: no failure then, so the draft is all that stops it.
            case "skipped" where pull.draft == true: continue
            case "neutral", "skipped", "stale": return .blocked("its check \(run.name) did not pass (\(run.conclusion ?? ""))")
            default: running = true   // a conclusion AiTerm does not know is not green
            }
        }
        for status in statuses {
            switch status.state {
            case "success": continue
            case "failure", "error": return .blocked("its status \(status.context) failed")
            default: running = true
            }
        }
        if running { return .waiting("its checks are running") }
        // A draft is said once its checks and its conflicts have: what else stops it comes first.
        if pull.draft == true { return pull.mergeable == false ? .blocked("it has conflicts") : .blocked(MergeReadiness.draftReason) }
        switch pull.mergeableState ?? "unknown" {
        case "clean", "has_hooks": return pull.mergeable == true ? .ready(head: pull.head.sha) : .waiting("GitHub is checking it")
        case "dirty": return .blocked("it has conflicts")
        case "behind": return .blocked("it is behind its base branch")
        case "blocked": return .waiting("it needs a review or a required check")
        case "draft": return .blocked(MergeReadiness.draftReason)
        // GitHub says a check does not pass that every list read here shows green: not ready until it agrees.
        case "unstable": return .waiting("GitHub says its checks are not all passing")
        default: return .waiting("GitHub is checking it")
        }
    }

    /// The pull request as the Operator reads it (`MergeRequestState`). `mergeable` is GitHub's `mergeable_state`
    /// (`merged` or `closed` once it is); `pipeline` is its checks as one word, nil when a list was not read to its end
    /// or there are no checks at all: a failed check first, then one still running, else `success`.
    public func mergeRequestState(repo: String, number: Int, url: String) async throws -> MergeRequestState {
        async let read = get(PullStatusPayload.self, path: "/repos/\(repo)/pulls/\(number)", notFound: .repoNotFound(repo))
        async let approved = approvals(repo: repo, number: number)
        let (pull, by) = try await (read, approved)
        let commit = "/repos/\(repo)/commits/\(pull.head.sha)"
        var pipeline: String?
        async let readRuns = listed(CheckRunsPayload.self, path: commit + "/check-runs", repo: repo)
        async let readStatuses = listed(CombinedStatusPayload.self, path: commit + "/status", repo: repo)
        if let runs = try await readRuns, let statuses = try await readStatuses, !runs.isEmpty || !statuses.isEmpty {
            let failed = runs.contains { $0.status == "completed" && ["failure", "timed_out", "startup_failure", "cancelled", "action_required"].contains($0.conclusion ?? "") }
                || statuses.contains { $0.state == "failure" || $0.state == "error" }
            let done = runs.allSatisfy { $0.status == "completed" && $0.conclusion != nil && $0.conclusion != "stale" }
                && statuses.allSatisfy { $0.state == "success" }
            pipeline = failed ? "failure" : done ? "success" : "pending"
        }
        let mergeable = pull.merged == true ? "merged" : pull.state == "open" ? pull.mergeableState ?? "unknown" : "closed"
        return MergeRequestState(iid: number, url: url, draft: pull.draft ?? false, pipeline: pipeline, mergeable: mergeable,
                                 approvedBy: by, head: pull.head.sha)
    }

    /// Every item of a paged list that reports its own `total`, a page of 100 at a time. HTTPJSON shows no
    /// headers and a short page proves nothing, so it reads until it holds `total` items or a page is empty,
    /// and nil — not a partial list — when that is fewer, or `listedPages` pages did not reach it.
    private func listed<Page: PagedList>(_ type: Page.Type, path: String, repo: String) async throws -> [Page.Item]? {
        var items: [Page.Item] = []
        for page in 1...Self.listedPages {
            let query = [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))]
            let batch = try await get(Page.self, path: path, query: query, notFound: .repoNotFound(repo))
            items += batch.items
            if items.count >= batch.total { return items }
            if batch.items.isEmpty { return nil }
        }
        return nil
    }

    /// Merges it at `sha`, the accepted commit: GitHub refuses (409) when the head is any other. Only
    /// `sha` is sent, so the merge is GitHub's own default, a merge commit — never a squash or a rebase,
    /// never auto-merge, never the branch deleted. A refusal is `.blocked`; only a failure to ask throws.
    /// An answer that does not say it merged is `.waiting`: `mergeReadiness` says when it has.
    public func merge(repo: String, number: Int, sha: String) async throws -> MergeReadiness {
        struct Merge: Encodable { var sha: String }
        struct Merged: Decodable { var sha: String?, merged: Bool? }
        do {
            let answer = try await send(Merged.self, method: "PUT", path: "/repos/\(repo)/pulls/\(number)/merge",
                                        body: Merge(sha: sha), notFound: .repoNotFound(repo))
            guard answer.merged == true, let commit = answer.sha, !commit.isEmpty else { return .waiting("GitHub has not finished merging it") }
            // GitHub merges at `sha` only when it is the head.
            return .merged(commit: commit, head: sha)
        } catch GitHubError.badResponse(409) {
            return .blocked("the branch moved past the accepted commit")
        } catch GitHubError.badResponse(let status) where [405, 422].contains(status) {
            return .blocked("GitHub refused to merge it (HTTP \(status))")
        }
    }

    /// Points it at `target`: a stacked pull request, once its parent has merged.
    public func retarget(repo: String, number: Int, to target: String) async throws {
        struct Retarget: Encodable { var base: String }
        _ = try await send(PullPayload.self, method: "PATCH", path: "/repos/\(repo)/pulls/\(number)",
                           body: Retarget(base: target), notFound: .repoNotFound(repo))
    }

    // MARK: The Review slice (spec §5): people on the pull request, only for an operator whose broadcast allows it.
    // A fine-grained token needs write access to pull requests.

    static let readyMutation = """
        mutation($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { isDraft } } }
        """

    /// Takes it out of draft. REST cannot, so this is GraphQL's `markPullRequestReadyForReview`, on the
    /// pull request's node id. One that is not a draft is not written to.
    public func markReady(repo: String, number: Int, beforeWrite: @Sendable () async throws -> Void = {}) async throws {
        struct Pull: Decodable { var nodeId: String?, draft: Bool? }
        let pull = try await get(Pull.self, path: "/repos/\(repo)/pulls/\(number)", notFound: .repoNotFound(repo))
        guard pull.draft == true else { return }
        guard let node = pull.nodeId else { throw GitHubError.decoding }
        try await beforeWrite()
        struct Variables: Encodable { var id: String }
        struct Done: Decodable {}
        _ = try await graphQL(Done.self, query: Self.readyMutation, variables: Variables(id: node), repo: repo)
    }

    /// Asks `logins` to review it; GitHub keeps whoever it asked already, and asking again is no change.
    public func requestReviewers(repo: String, number: Int, logins: [String]) async throws {
        struct Request: Encodable { var reviewers: [String] }
        struct Answer: Decodable { var number: Int? }
        _ = try await send(Answer.self, method: "POST", path: "/repos/\(repo)/pulls/\(number)/requested_reviewers",
                           body: Request(reviewers: logins), notFound: .repoNotFound(repo))
    }

    /// One query, never a mutation: each review thread with its id, whether it is resolved, and its last comment.
    static let threadDetailsQuery = """
        query($owner: String!, $name: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              reviewThreads(first: \(threadsPerPage), after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { id isResolved comments(last: 1) { nodes { body author { login } } } }
              }
            }
          }
        }
        """

    /// Its review threads, each with its node id and its last comment, read to the last page: a page past
    /// `threadPagesRead`, a cursor that does not move on or a thread that does not decode throws `IncompleteRead`, so
    /// nothing is decided on part of them.
    public func threads(repo: String, number: Int) async throws -> [ReviewThread] {
        try await readThreads(ThreadDetail.self, repo: repo, number: number, complete: true,
            answer: { (answer: GraphQLAnswer<ThreadsPayload<ThreadDetail>, GraphQLProblem>) in try answer.checked(repo: repo) },
            items: { nodes in
                try nodes.map { entry in
                    guard let node = entry.value else { throw IncompleteRead("review threads") }
                    let last = node.comments?.nodes?.last
                    return ReviewThread(id: node.id, resolved: node.isResolved, lastAuthor: last?.author?.login, lastBody: last?.body ?? "")
                }
            })
    }

    /// Both thread projections use the same repository binding and paged query. Only publication
    /// requires complete, strictly decoded pages; badges retain their bounded, lenient read.
    private func readThreads<Node: Decodable, Problem: Decodable, Item>(_ type: Node.Type, repo: String, number: Int, complete: Bool,
        answer: (GraphQLAnswer<ThreadsPayload<Node>, Problem>) throws -> ThreadsPayload<Node>,
        items: ([Lenient<Node>]) throws -> [Item]) async throws -> [Item] {
        guard let (owner, name) = Self.ownerAndName(repo) else { throw GitHubError.repoNotFound(repo) }
        return try await graphQLPages(ThreadsPayload<Node>.self, query: complete ? Self.threadDetailsQuery : Self.threadsQuery,
            variables: { ThreadVariables(owner: owner, name: name, number: number, after: $0) }, repo: repo,
            limit: complete ? Self.threadPagesRead : Self.threadPages,
            exhausted: complete ? IncompleteRead("review threads") : nil,
            invalidCursor: complete ? IncompleteRead("review threads") : nil, answer: answer,
            page: { payload in
                guard let threads = payload.repository?.pullRequest?.reviewThreads else { throw GitHubError.repoNotFound(repo) }
                return (try items(threads.nodes), threads.pageInfo)
            })
    }

    static let replyMutation = """
        mutation($thread: ID!, $body: String!) {
          addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $thread, body: $body}) { comment { id } }
        }
        """

    /// A reply in the review thread `thread`, by its node id.
    public func reply(repo: String, thread: String, body: String) async throws {
        struct Variables: Encodable { var thread: String, body: String }
        struct Done: Decodable {}
        _ = try await graphQL(Done.self, query: Self.replyMutation, variables: Variables(thread: thread, body: body), repo: repo)
    }

    /// The people who may be assigned in `repo` whose login matches `query`. GitHub lists assignees by login
    /// only, so a name is not known.
    public func findUsers(repo: String, query: String) async throws -> [HostUser] {
        struct User: Decodable { var login: String }
        let users = try await get([User].self, path: "/repos/\(repo)/assignees", query: [URLQueryItem(name: "per_page", value: "100")],
                                  notFound: .repoNotFound(repo))
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        return users.filter { text.isEmpty || $0.login.range(of: text, options: .caseInsensitive) != nil }
            .map { HostUser(username: $0.login, name: nil) }
    }

    /// Who approved it, by login: each reviewer's latest review that approves or asks for changes counts. Every page
    /// is read, a page of 100 at a time until an empty one; `threadPagesRead` pages without reaching it throws
    /// `IncompleteRead`, as a later review may take an approval back.
    public func approvals(repo: String, number: Int) async throws -> [String] {
        struct Review: Decodable { struct User: Decodable { var login: String? }; var user: User?, state: String? }
        let reviews = try await HTTPJSON.pagesUntilEmpty(limit: Self.threadPagesRead, exhausted: IncompleteRead("reviews")) { page in
            try await get([Review].self, path: "/repos/\(repo)/pulls/\(number)/reviews",
                          query: [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))],
                          notFound: .repoNotFound(repo))
        } items: { $0 }
        var latest: [String: String] = [:], order: [String] = []
        for review in reviews {
            guard let login = review.user?.login, let state = review.state, state == "APPROVED" || state == "CHANGES_REQUESTED" || state == "DISMISSED" else { continue }
            if latest[login] == nil { order.append(login) }
            latest[login] = state
        }
        return order.filter { latest[$0] == "APPROVED" }
    }

    /// One GraphQL request: its data, or the first error beside it as GitHub's refusal.
    private func graphQL<Variables: Encodable, Payload: Decodable>(_ type: Payload.Type, query: String, variables: Variables,
                                                                   repo: String) async throws -> Payload {
        try await graphQL(type, query: query, variables: variables, repo: repo,
                          answer: { (answer: GraphQLAnswer<Payload, GraphQLProblem>) in try answer.checked(repo: repo) })
    }

    /// The shared request/envelope path; callers retain the error policy of the read they serve.
    private func graphQL<Variables: Encodable, Payload: Decodable, Problem: Decodable>(_ type: Payload.Type, query: String,
        variables: Variables, repo: String, answer: (GraphQLAnswer<Payload, Problem>) throws -> Payload) async throws -> Payload {
        try answer(await post(GraphQLAnswer<Payload, Problem>.self, path: "/graphql",
                              body: GraphQLRequest(query: query, variables: variables), notFound: .repoNotFound(repo)))
    }

    /// A cursor listing, validated one page at a time. A nil exhaustion/cursor error preserves a
    /// badge's bounded, lenient read; complete reads supply their own refusal at either boundary.
    private func graphQLPages<Variables: Encodable, Payload: Decodable, Problem: Decodable, Item>(_ type: Payload.Type, query: String,
        variables: (String?) -> Variables, repo: String, limit: Int, exhausted: (any Error)?, invalidCursor: (any Error)?,
        allowEmptyCursor: Bool = true, answer: (GraphQLAnswer<Payload, Problem>) throws -> Payload,
        page: (Payload) throws -> ([Item], GraphQLPageInfo)) async throws -> [Item] {
        var result: [Item] = [], cursor: String?
        for _ in 0..<limit {
            let payload = try await graphQL(type, query: query, variables: variables(cursor), repo: repo, answer: answer)
            let (items, info) = try page(payload)
            result += items
            guard let next = try info.next(after: cursor, allowEmpty: allowEmptyCursor, invalid: invalidCursor) else { return result }
            cursor = next
        }
        if let exhausted { throw exhausted }
        return result
    }

    /// The ruleset rule types that do not stop AiTerm pushing its own branch: they forbid force-pushes or
    /// deletion (AiTerm does neither) or constrain what is pushed — signatures, linear history, message,
    /// e-mail, branch-name, path, extension and size patterns — which GitHub enforces at push time and
    /// which a conforming push to a feature branch meets. A ruleset rule of any other type covers the
    /// branch, and so is protection: `update`, `creation`, `pull_request`, `required_status_checks`,
    /// `required_deployments`, `merge_queue`, `workflows`, `code_scanning`, and any type GitHub adds later.
    static let harmlessRules: Set<String> = [
        "non_fast_forward", "deletion", "required_signatures", "required_linear_history", "commit_message_pattern",
        "commit_author_email_pattern", "committer_email_pattern", "branch_name_pattern", "file_path_restriction",
        "max_file_path_length", "file_extension_restriction", "max_file_size",
    ]

    /// Whether GitHub protects `branch` in `repo`, asked before AiTerm pushes it. Three sources, read in
    /// full: the rulesets that apply to the branch, org-level ones too, whether or not it exists yet
    /// (`/rules/branches/…`); the branch's own `protected` flag when GitHub already has it; and — only when
    /// it does not yet — the patterns of the classic protection rules, which would cover it once pushed.
    /// A token needs read access to the repository's metadata, and administration for the last.
    /// Anything that cannot be read whole throws `ProtectionUnknown`: an error, a refusal, a body that does
    /// not decode, a list longer than AiTerm reads, a rule it cannot evaluate. Never "unprotected" by default.
    public func branchProtection(repo: String, branch: String) async throws -> BranchProtection {
        let name = branch.hasPrefix("refs/heads/") ? String(branch.dropFirst("refs/heads/".count)) : branch
        guard !name.isEmpty else { throw ProtectionUnknown.unreadable("There is no branch name to check") }
        do { return try await protection(repo: repo, branch: name) }
        catch let error as GitHubError {
            let why = (error.errorDescription ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            throw ProtectionUnknown.unreadable("AiTerm could not read GitHub’s protection of \(name) in \(repo): \(why)")
        }
    }

    private func protection(repo: String, branch name: String) async throws -> BranchProtection {
        guard Self.ownerAndName(repo) != nil else { throw GitHubError.repoNotFound(repo) }
        let segment = HTTPJSON.pathSegment(name)
        struct Rule: Decodable { var type: String }
        var listedWhole = false
        for page in 1...Self.listedPages {
            let query = [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))]
            let rules = try await get([Rule].self, path: "/repos/\(repo)/rules/branches/\(segment)", query: query,
                                      notFound: .repoNotFound(repo))
            if let rule = rules.first(where: { !Self.harmlessRules.contains($0.type) }) {
                return .protected("a ruleset’s \(rule.type.replacingOccurrences(of: "_", with: " ")) rule covers it")
            }
            if rules.isEmpty { listedWhole = true; break }
        }
        guard listedWhole else { throw ProtectionUnknown.tooManyRules(Self.listedPages * 100) }
        struct Branch: Decodable { var name: String, protected: Bool }
        do {
            let existing = try await get(Branch.self, path: "/repos/\(repo)/branches/\(segment)", notFound: .badResponse(404))
            // A renamed branch's old name redirects to the new one, whose flag says nothing of the old.
            guard existing.name == name else { throw ProtectionUnknown.unreadable("GitHub answered for the branch \(existing.name), not \(name)") }
            return existing.protected ? .protected("GitHub’s branch protection covers it") : .unprotected
        } catch GitHubError.badResponse(404) {
            // The repository was just read, so this is a branch GitHub does not have yet: a classic
            // rule's pattern may still cover it once pushed.
        }
        var unreadable: ProtectionUnknown?
        for pattern in try await protectionPatterns(repo: repo) {
            do {
                if try BranchProtection.evaluate(pattern, name, starCrossesSlash: false) {
                    return .protected("the branch protection rule \(pattern) covers it")
                }
            } catch let error as ProtectionUnknown { unreadable = unreadable ?? error }
        }
        if let unreadable { throw unreadable }
        return .unprotected
    }

    static let protectionRulesQuery = """
        query($owner: String!, $name: String!, $after: String) {
          repository(owner: $owner, name: $name) {
            branchProtectionRules(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { pattern } }
          }
        }
        """

    /// The patterns of `repo`'s classic branch protection rules, through GraphQL (REST lists them to
    /// admins only), every page. A null repository, any error beside the data, a rule that does not
    /// decode, or more pages than are read is no answer.
    func protectionPatterns(repo: String) async throws -> [String] {
        guard let (owner, name) = Self.ownerAndName(repo) else { throw GitHubError.repoNotFound(repo) }
        struct Variables: Encodable { var owner: String, name: String, after: String? }
        struct Problem: Decodable { var message: String? }
        struct Node: Decodable { var pattern: String }
        struct Rules: Decodable { var pageInfo: GraphQLPageInfo, nodes: [Node] }
        struct Repository: Decodable { var branchProtectionRules: Rules }
        struct Payload: Decodable { var repository: Repository? }
        return try await graphQLPages(Payload.self, query: Self.protectionRulesQuery,
            variables: { Variables(owner: owner, name: name, after: $0) }, repo: repo, limit: Self.listedPages,
            exhausted: ProtectionUnknown.tooManyRules(Self.listedPages * 100),
            invalidCursor: ProtectionUnknown.unreadable("GitHub didn’t page \(repo)’s branch protection rules"), allowEmptyCursor: false,
            answer: { (answer: GraphQLAnswer<Payload, Problem>) in
                if let problem = answer.errors?.first {
                    throw ProtectionUnknown.unreadable("GitHub didn’t show \(repo)’s branch protection rules (\(problem.message ?? "an error"))")
                }
                guard let data = answer.data, data.repository != nil else {
                    throw ProtectionUnknown.unreadable("GitHub didn’t show \(repo)’s branch protection rules")
                }
                return data
            }, page: { payload in
                guard let rules = payload.repository?.branchProtectionRules else {
                    throw ProtectionUnknown.unreadable("GitHub didn’t show \(repo)’s branch protection rules")
                }
                return (rules.nodes.map(\.pattern), rules.pageInfo)
            })
    }

    /// The token and the API version every request carries.
    private var headers: [String: String] {
        ["Authorization": "Bearer \(config.token)", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
    }

    private func get<Payload: Decodable>(_ type: Payload.Type, path: String, query: [URLQueryItem] = [],
                                         notFound: GitHubError) async throws -> Payload {
        try await api(notFound).get(type, path: path, query: query)
    }

    private func post<Body: Encodable, Payload: Decodable>(_ type: Payload.Type, path: String, body: Body,
                                                           notFound: GitHubError) async throws -> Payload {
        try await send(type, method: "POST", path: path, body: body, notFound: notFound)
    }

    private func send<Body: Encodable, Payload: Decodable>(_ type: Payload.Type, method: String, path: String, body: Body,
                                                           notFound: GitHubError) async throws -> Payload {
        try await api(notFound).send(type, method: method, path: path, body: body)
    }

    /// `notFound` is what a 404 means for the path asked.
    private func api(_ notFound: GitHubError) -> HostAPI {
        HostAPI(base: Self.api, headers: headers, session: session, malformed: GitHubError.decoding,
                mapping: { Self.error(for: $0, notFound: notFound) })
    }

    static func error(for failure: HTTPJSON.Failure, notFound: GitHubError) -> GitHubError {
        switch failure {
        case .transport(let error): return .network(error.localizedDescription)
        case .undecodable: return .decoding
        case .status(401): return .unauthorized
        case .status(403): return .forbidden
        case .status(404): return notFound
        case .status(let status): return .badResponse(status)
        }
    }
}

/// The fields of a pull request the picker shows.
private struct PullPayload: Decodable {
    struct User: Decodable { var login: String? }
    struct Repo: Decodable { var fullName: String? }
    struct Ref: Decodable { var ref: String, label: String?, repo: Repo? }
    var number: Int, title: String, htmlUrl: String, draft: Bool?, user: User?, head: Ref, base: Ref
    /// A pull request fetched by number can be closed or merged; the list holds open ones only,
    /// and omits `merged`.
    var state: String?, merged: Bool?

    /// A head in another repository — or in none, once its fork was deleted — is a fork's.
    var mergeRequest: MergeRequest {
        let headRepo = head.repo?.fullName?.lowercased(), baseRepo = base.repo?.fullName?.lowercased()
        let fork = headRepo == nil || headRepo != baseRepo
        return MergeRequest(iid: number, title: title, sourceBranch: head.ref, targetBranch: base.ref,
                            author: user?.login, state: merged == true ? "merged" : (state ?? "open"),
                            draft: draft ?? false, url: htmlUrl,
                            forkHead: fork ? (head.label ?? "ghost:\(head.ref)") : nil)
    }
}

/// One GraphQL request, and its answer: the data, or the errors beside it.
private struct GraphQLRequest<Variables: Encodable>: Encodable { var query: String, variables: Variables }
private struct GraphQLAnswer<Payload: Decodable, Problem: Decodable>: Decodable {
    var data: Payload?, errors: [Problem]?
}

private struct GraphQLProblem: Decodable { var type: String?, message: String? }

extension GraphQLAnswer where Problem == GraphQLProblem {
    func checked(repo: String) throws -> Payload {
        if let problem = errors?.first {
            switch problem.type {
            case "FORBIDDEN": throw GitHubError.forbidden
            case "NOT_FOUND": throw GitHubError.repoNotFound(repo)
            default: throw GitHubError.refused(problem.message ?? "an error")
            }
        }
        guard let data else { throw GitHubError.decoding }
        return data
    }
}

private struct ThreadVariables: Encodable { var owner: String, name: String, number: Int, after: String? }
/// Badge reads intentionally ignore error messages and the thread detail fields.
private struct ThreadProblem: Decodable { var type: String? }
private struct ThreadResolution: Decodable { var isResolved: Bool }
private struct ThreadDetail: Decodable {
    struct Comment: Decodable { struct Author: Decodable { var login: String? }; var body: String?, author: Author? }
    struct Comments: Decodable { var nodes: [Comment]? }
    var id: String, isResolved: Bool, comments: Comments?
}

/// The same GraphQL connection, projected as badge resolutions or publication thread details.
private struct ThreadsPayload<Node: Decodable>: Decodable {
    struct Threads: Decodable { var pageInfo: GraphQLPageInfo, nodes: [Lenient<Node>] }
    struct PullRequest: Decodable { var reviewThreads: Threads }
    struct Repository: Decodable { var pullRequest: PullRequest? }
    var repository: Repository?
}

/// A list a page at a time that says how many items it holds in all.
private protocol PagedList: Decodable {
    associatedtype Item
    var items: [Item] { get }
    var total: Int { get }
}

/// The fields of a pull request that say whether it can merge now.
private struct PullStatusPayload: Decodable {
    struct Base: Decodable { var ref: String }
    var base: Base?
    struct Head: Decodable { var sha: String }
    var state: String, draft: Bool?, merged: Bool?, mergeable: Bool?, mergeableState: String?, mergeCommitSha: String?
    var head: Head
}

/// A commit's check runs (GitHub Actions and other apps).
private struct CheckRunsPayload: PagedList {
    struct Run: Decodable { var name: String, status: String, conclusion: String? }
    var totalCount: Int, checkRuns: [Run]
    var items: [Run] { checkRuns }
    var total: Int { totalCount }
}

/// A commit's statuses (the older API some CI still reports through).
private struct CombinedStatusPayload: PagedList {
    struct Status: Decodable { var context: String, state: String }
    var totalCount: Int, statuses: [Status]
    var items: [Status] { statuses }
    var total: Int { totalCount }
}


private struct GraphQLPageInfo: Decodable {
    var hasNextPage: Bool, endCursor: String?
    func next(after previous: String?, allowEmpty: Bool = true, invalid: (any Error)?) throws -> String? {
        guard hasNextPage else { return nil }
        // Badges have always accepted repeated cursors and stopped on a missing one, up to their cap.
        guard let invalid else { return endCursor }
        guard let next = endCursor, next != previous, allowEmpty || !next.isEmpty else { throw invalid }
        return next
    }
}
