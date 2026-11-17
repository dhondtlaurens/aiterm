import Foundation

extension GitHubClient {
    public func reviewers(of number: Int) async throws -> [String] {
        struct Team: Decodable { var slug: String }
        struct Reviewers: Decodable { var users: [ReviewActivityLogin]; var teams: [Team] }
        let value = try await Self.api(config, session: session, notFound: .repoNotFound(repo))
            .get(Reviewers.self, path: Self.repositoryPath(repo) + "/pulls/\(number)/requested_reviewers")
        return value.users.compactMap(\.login) + value.teams.map { "team:" + $0.slug }
    }
    public func myReviewPostedAt(of number: Int) async throws -> Date? {
        let path = Self.repositoryPath(repo)
        async let readReviews: [SubmittedReview] = reviewActivityPages(path + "/pulls/\(number)/reviews")
        async let readComments: [ReviewComment] = reviewActivityPages(path + "/issues/\(number)/comments")
        async let readInline: [InlineReviewComment] = reviewActivityPages(path + "/pulls/\(number)/comments")
        let user = try await currentUser().lowercased()
        let (reviews, comments, inline) = try await (readReviews, readComments, readInline)
        var dates: [Date] = [], posted: Set<Int> = []
        for review in reviews where review.state != "PENDING" {
            guard let text = review.submittedAt, let date = HostDate.iso8601(text) else { throw IncompleteRead("submitted reviews") }
            posted.insert(review.id)
            if review.user?.login?.lowercased() == user { dates.append(date) }
        }
        for comment in comments {
            guard let date = HostDate.iso8601(comment.createdAt) else { throw IncompleteRead("review comments") }
            if comment.user?.login?.lowercased() == user { dates.append(date) }
        }
        for comment in inline {
            guard let date = HostDate.iso8601(comment.createdAt) else { throw IncompleteRead("inline comments") }
            if comment.user?.login?.lowercased() == user, posted.contains(comment.pullRequestReviewId) { dates.append(date) }
        }
        return dates.max()
    }
    private func reviewActivityPages<Value: Decodable>(_ path: String) async throws -> [Value] {
        let api = Self.api(config, session: session, notFound: .repoNotFound(repo))
        let read = try await HTTPJSON.pages(perPage: 100, limit: 100, ending: .shortPage) { page in
            try await api.get([Value].self, path: path, query: [URLQueryItem(name: "per_page", value: "100"),
                                                              URLQueryItem(name: "page", value: String(page))])
        }
        guard read.complete else { throw IncompleteRead("review activity") }
        return read.items
    }
}
private struct ReviewActivityLogin: Decodable, Sendable { var login: String? }
private struct SubmittedReview: Decodable, Sendable { var id: Int; var user: ReviewActivityLogin?; var state: String; var submittedAt: String? }
private struct ReviewComment: Decodable, Sendable { var user: ReviewActivityLogin?; var createdAt: String }
private struct InlineReviewComment: Decodable, Sendable { var user: ReviewActivityLogin?; var pullRequestReviewId: Int; var createdAt: String }
