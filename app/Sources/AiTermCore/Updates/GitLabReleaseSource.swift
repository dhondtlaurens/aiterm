import Foundation

/// Releases of one GitLab project, read with the token from Settings. The newest release comes from
/// the release list rather than `releases/permalink/latest`, which only redirects to it, and from a
/// page of them rather than the first; `ReleasePage` picks from it. The disk image is the asset
/// link's `url` — the package-registry API URL, which accepts the token — not its
/// `direct_asset_url`, a web route that redirects there.
///
/// The token goes to the feed's own origin (scheme, host and port) and nowhere else: a request
/// carries it only there, and `HTTPJSON` drops it from any redirect hop that leaves.
public struct GitLabReleaseSource: ReleaseSource {
    public let host: URL, project: String, token: String
    let session: URLSession

    public init(host: URL, project: String, token: String, session: URLSession = .shared) {
        self.host = host; self.project = project; self.token = token; self.session = session
    }

    public func latest() async throws -> Release {
        guard let url = GitLabClient.apiURL(host: host, path: "/api/v4/projects/" + GitLabClient.encodedProject(project) + "/releases",
                                            query: [URLQueryItem(name: "per_page", value: "20")])
        else { throw UpdateError.projectNotFound(.gitLab, project) }
        let (page, status) = try await HTTPJSON.decode([Lenient<ReleasePayload>].self, request(url, timeout: 15), session: session) {
            mapped($0, listing: true)
        }
        return try ReleasePage.newest(page.map { $0.value?.entry }, host: .gitLab, status: status)
    }

    /// Streamed to disk, not held in memory: the disk image is the whole app bundle.
    public func download(_ release: Release, to destination: URL) async throws {
        try await ReleaseDownload.save(request(release.assetURL, timeout: 300), to: destination, session: session) {
            mapped($0, listing: false)
        }
    }

    private func request(_ url: URL, timeout: TimeInterval) -> URLRequest {
        // The asset link is whatever a release editor typed.
        HTTPJSON.request(url, headers: url.isSameOrigin(as: host) ? ["PRIVATE-TOKEN": token] : [:], timeout: timeout)
    }

    /// A 404 for the release list is the project; for a disk image it is only a bad link. A
    /// listing that is no release list at all is a bad response, whatever its status.
    private func mapped(_ failure: HTTPJSON.Failure, listing: Bool) -> UpdateError {
        switch failure {
        case .transport: return .unreachable(host.host ?? host.absoluteString)
        case .status(401), .status(403): return .rejected
        case .status(404) where listing: return .projectNotFound(.gitLab, project)
        case .status(let status), .undecodable(let status): return .badResponse(.gitLab, status)
        }
    }
}

/// The fields of one entry of GitLab's release list that an update needs.
private struct ReleasePayload: Decodable {
    struct Assets: Decodable { var links: [Lenient<Link>]? }
    struct Link: Decodable { var name: String?, url: String? }
    var tagName: String?, assets: Assets?

    var entry: ReleaseEntry {
        let links = assets?.links?.compactMap(\.value) ?? []
        let named = links.compactMap { link in link.name.flatMap { name in link.url.flatMap(URL.init(string:)).map { (name, $0) } } }
        return ReleaseEntry(tag: tagName, assets: Dictionary(named, uniquingKeysWith: { first, _ in first }))
    }
}
