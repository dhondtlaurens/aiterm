import Foundation

extension GitLabClient {
    public func myReviewPostedAt(of number: Int) async throws -> Date? {
        struct User: Decodable { var username: String? }
        struct Note: Decodable { var author: User?; var body: String; var system: Bool; var createdAt: String }
        let api = Self.api(config, session: session, notFound: .projectNotFound(project))
        let user = try await currentUser().lowercased()
        let read = try await HTTPJSON.pages(perPage: 100, limit: 100, ending: .shortPage) { page in
            try await api.get([Note].self, path: Self.projectPath(project) + "/merge_requests/\(number)/notes",
                              query: [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(page))])
        }
        guard read.complete else { throw IncompleteRead("review activity") }
        var dates: [Date] = []
        for note in read.items {
            guard let date = HostDate.iso8601(note.createdAt) else { throw IncompleteRead("review activity") }
            // GitLab records approvals as system notes. Other system activity (assignment, edits,
            // commits) is not a posted review. Draft notes live on a separate API and never enter here.
            if note.author?.username?.lowercased() == user, !note.system || note.body == "approved this merge request" { dates.append(date) }
        }
        return dates.max()
    }
}
