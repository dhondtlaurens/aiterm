import Foundation

public struct GitHubConfig: Equatable, Sendable {
    public var token: String
    public init(token: String) { self.token = token }
}

public enum GitHubError: Error, Equatable, LocalizedError {
    case unauthorized, forbidden, network(String), badResponse(Int), decoding, repoNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "Check your GitHub access token in Settings › Integrations."
        // GitHub answers both a token without access to the repository and a spent rate limit with 403.
        case .forbidden: return "GitHub refused: the token can’t read this repository, or the rate limit was reached."
        case .network(let message): return "Couldn’t connect to GitHub. \(message)"
        case .badResponse(let status): return "GitHub returned an error (HTTP \(status)). Try again."
        case .decoding: return "Couldn’t read GitHub’s response. Try again."
        case .repoNotFound(let path): return "GitHub has no repository at \(path), or your token cannot see it."
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
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw GitHubError.repoNotFound(repo) }
        var resolutions: [Bool] = [], cursor: String?
        for _ in 0..<Self.threadPages {
            let variables = ThreadsRequest.Variables(owner: parts[0], name: parts[1], number: number, after: cursor)
            let page = try await post(ThreadsPayload.self, path: "/graphql",
                                      body: ThreadsRequest(query: Self.threadsQuery, variables: variables),
                                      notFound: .repoNotFound(repo))
            guard let threads = page.data?.repository?.pullRequest?.reviewThreads else {
                throw page.errors?.contains { $0.type == "FORBIDDEN" } == true ? GitHubError.forbidden : GitHubError.repoNotFound(repo)
            }
            resolutions += threads.nodes.compactMap { $0.value?.isResolved }
            guard threads.pageInfo.hasNextPage, let next = threads.pageInfo.endCursor else { break }
            cursor = next
        }
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

    /// A branch name as **one** path segment: a `/` inside it must not split the path.
    static func encodedBranch(_ name: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
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
        // URLComponents leaves a `+` in a value alone, and GitHub reads it as a space: a branch `feat/a+b`
        // would be looked for as `feat/a b`.
        guard let url = HTTPJSON.url(Self.api + "/repos/\(repo)/pulls", query: query),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw GitHubError.decoding }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let encoded = components.url else { throw GitHubError.decoding }
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
    /// alone, so a caller debounces a ready answer): merged or closed first, then a draft, then every check run and
    /// commit status on its head — a merge end waits for green whatever branch protection requires; a
    /// skipped, neutral or action-required check is not green and a pending one is not yet — then
    /// `mergeable` and `mergeable_state`. Only `clean` and `has_hooks` with `mergeable` true is ready.
    public func mergeReadiness(repo: String, number: Int) async throws -> MergeReadiness {
        let pull = try await get(PullStatusPayload.self, path: "/repos/\(repo)/pulls/\(number)", notFound: .repoNotFound(repo))
        if pull.merged == true { return .merged(commit: pull.mergeCommitSha ?? pull.head.sha) }
        guard pull.state == "open" else { return .blocked("the pull request is closed") }
        if pull.draft == true { return .blocked("it is a draft") }
        let commit = "/repos/\(repo)/commits/\(pull.head.sha)"
        guard let runs = try await listed(CheckRunsPayload.self, path: commit + "/check-runs", repo: repo),
              let statuses = try await listed(CombinedStatusPayload.self, path: commit + "/status", repo: repo) else {
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
        switch pull.mergeableState ?? "unknown" {
        case "clean", "has_hooks": return pull.mergeable == true ? .ready(head: pull.head.sha) : .waiting("GitHub is checking it")
        case "dirty": return .blocked("it has conflicts")
        case "behind": return .blocked("it is behind its base branch")
        case "blocked": return .waiting("it needs a review or a required check")
        case "draft": return .blocked("it is a draft")
        // GitHub says a check does not pass that every list read here shows green: not ready until it agrees.
        case "unstable": return .waiting("GitHub says its checks are not all passing")
        default: return .waiting("GitHub is checking it")
        }
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
            return .merged(commit: commit)
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
        let segment = Self.encodedBranch(name)
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
        struct Request: Encodable {
            struct Variables: Encodable { var owner: String, name: String, after: String? }
            var query: String, variables: Variables
        }
        struct Answer: Decodable {
            struct Problem: Decodable { var message: String? }
            struct Node: Decodable { var pattern: String }
            struct PageInfo: Decodable { var hasNextPage: Bool, endCursor: String? }
            struct Rules: Decodable { var pageInfo: PageInfo, nodes: [Node] }
            struct Repository: Decodable { var branchProtectionRules: Rules }
            struct Payload: Decodable { var repository: Repository? }
            var data: Payload?, errors: [Problem]?
        }
        var patterns: [String] = [], cursor: String?
        for _ in 0..<Self.listedPages {
            let answer = try await post(Answer.self, path: "/graphql",
                                        body: Request(query: Self.protectionRulesQuery, variables: .init(owner: owner, name: name, after: cursor)),
                                        notFound: .repoNotFound(repo))
            if let problem = answer.errors?.first {
                throw ProtectionUnknown.unreadable("GitHub didn’t show \(repo)’s branch protection rules (\(problem.message ?? "an error"))")
            }
            guard let rules = answer.data?.repository?.branchProtectionRules else {
                throw ProtectionUnknown.unreadable("GitHub didn’t show \(repo)’s branch protection rules")
            }
            patterns += rules.nodes.map(\.pattern)
            if !rules.pageInfo.hasNextPage { return patterns }
            guard let next = rules.pageInfo.endCursor, !next.isEmpty, next != cursor else {
                throw ProtectionUnknown.unreadable("GitHub didn’t page \(repo)’s branch protection rules")
            }
            cursor = next
        }
        throw ProtectionUnknown.tooManyRules(Self.listedPages * 100)
    }

    /// The token and the API version every request carries.
    private var headers: [String: String] {
        ["Authorization": "Bearer \(config.token)", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
    }

    private func get<Payload: Decodable>(_ type: Payload.Type, path: String, query: [URLQueryItem] = [],
                                         notFound: GitHubError) async throws -> Payload {
        guard let url = HTTPJSON.url(Self.api + path, query: query) else { throw GitHubError.decoding }
        let request = HTTPJSON.request(url, headers: headers)
        return try await HTTPJSON.decode(type, request, session: session) { Self.error(for: $0, notFound: notFound) }.value
    }

    private func post<Body: Encodable, Payload: Decodable>(_ type: Payload.Type, path: String, body: Body,
                                                           notFound: GitHubError) async throws -> Payload {
        try await send(type, method: "POST", path: path, body: body, notFound: notFound)
    }

    private func send<Body: Encodable, Payload: Decodable>(_ type: Payload.Type, method: String, path: String, body: Body,
                                                           notFound: GitHubError) async throws -> Payload {
        guard let url = HTTPJSON.url(Self.api + path) else { throw GitHubError.decoding }
        var request = HTTPJSON.request(url, headers: headers.merging(["Content-Type": "application/json"]) { $1 })
        request.httpMethod = method
        request.httpBody = try JSONEncoder().encode(body)
        return try await HTTPJSON.decode(type, request, session: session) { Self.error(for: $0, notFound: notFound) }.value
    }

    /// `notFound` is what a 404 means for the path asked.
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

/// A GraphQL request for one page of a pull request's review threads.
private struct ThreadsRequest: Encodable {
    struct Variables: Encodable { var owner: String, name: String, number: Int, after: String? }
    var query: String, variables: Variables
}

/// GraphQL's answer for one page of review threads. Its keys are camelCase, which the snake-case
/// decoder leaves as they are. `repository` or `pullRequest` is null, with an error beside it, when
/// the token cannot see it or it is not there.
private struct ThreadsPayload: Decodable {
    struct Problem: Decodable { var type: String? }
    struct Node: Decodable { var isResolved: Bool }
    struct PageInfo: Decodable { var hasNextPage: Bool, endCursor: String? }
    struct Threads: Decodable { var pageInfo: PageInfo, nodes: [Lenient<Node>] }
    struct PullRequest: Decodable { var reviewThreads: Threads }
    struct Repository: Decodable { var pullRequest: PullRequest? }
    struct Answer: Decodable { var repository: Repository? }
    var data: Answer?, errors: [Problem]?
}

/// A list a page at a time that says how many items it holds in all.
private protocol PagedList: Decodable {
    associatedtype Item
    var items: [Item] { get }
    var total: Int { get }
}

/// The fields of a pull request that say whether it can merge now.
private struct PullStatusPayload: Decodable {
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
