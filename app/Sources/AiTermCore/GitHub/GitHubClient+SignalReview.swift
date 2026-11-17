import Foundation

extension GitHubClient: SignalHostReading {
    public func signalReviewers(of number: Int) async throws -> [String] {
        struct Team: Decodable { var slug: String }
        struct Reviewers: Decodable { var users: [SignalLogin]; var teams: [Team] }
        let value = try await Self.api(config, session: session, notFound: .repoNotFound(repo))
            .get(Reviewers.self, path: Self.repositoryPath(repo) + "/pulls/\(number)/requested_reviewers")
        return value.users.compactMap(\.login) + value.teams.map { "team:" + $0.slug }
    }
    public func mySignalReviewPostedAt(of number: Int) async throws -> Date? {
        let path = Self.repositoryPath(repo)
        async let readReviews: [SignalReview] = signalPages(path + "/pulls/\(number)/reviews")
        async let readComments: [SignalComment] = signalPages(path + "/issues/\(number)/comments")
        async let readInline: [SignalInlineComment] = signalPages(path + "/pulls/\(number)/comments")
        let user = try await currentUser().lowercased()
        let (reviews, comments, inline) = try await (readReviews, readComments, readInline)
        var dates: [Date] = [], posted: Set<Int> = []
        for review in reviews where review.state != "PENDING" {
            guard let text = review.submittedAt, let date = GitLabClient.date(text) else { throw IncompleteRead("submitted reviews") }
            posted.insert(review.id)
            if review.user?.login?.lowercased() == user { dates.append(date) }
        }
        for comment in comments {
            guard let date = GitLabClient.date(comment.createdAt) else { throw IncompleteRead("review comments") }
            if comment.user?.login?.lowercased() == user { dates.append(date) }
        }
        for comment in inline {
            guard let date = GitLabClient.date(comment.createdAt) else { throw IncompleteRead("inline comments") }
            if comment.user?.login?.lowercased() == user, posted.contains(comment.pullRequestReviewId) { dates.append(date) }
        }
        return dates.max()
    }
    private func signalPages<Value: Decodable>(_ path: String) async throws -> [Value] {
        let api = Self.api(config, session: session, notFound: .repoNotFound(repo))
        let read = try await HTTPJSON.pages(perPage: 100, limit: 100, ending: .shortPage) { page in
            try await api.get([Value].self, path: path, query: [URLQueryItem(name: "per_page", value: "100"),
                                                              URLQueryItem(name: "page", value: String(page))])
        }
        guard read.complete else { throw IncompleteRead("review activity") }
        return read.items
    }
}
private struct SignalLogin: Decodable, Sendable { var login: String? }
private struct SignalReview: Decodable, Sendable { var id: Int; var user: SignalLogin?; var state: String; var submittedAt: String? }
private struct SignalComment: Decodable, Sendable { var user: SignalLogin?; var createdAt: String }
private struct SignalInlineComment: Decodable, Sendable { var user: SignalLogin?; var pullRequestReviewId: Int; var createdAt: String }
