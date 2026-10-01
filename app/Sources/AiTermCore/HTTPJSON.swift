import Foundation

/// The request round the REST clients share — Jira, GitLab, GitHub and the release feeds. It sends the
/// request and tells a transport failure from a status outside 2xx; each client turns those into
/// its own error. Cancellation stays cancellation: a search dropped for a newer one is not a
/// network failure to report.
///
/// No credential leaves its origin. URLSession re-sends every header of the first request on each
/// redirect hop, so a server that redirects elsewhere — GitLab sends a package download to object
/// storage — would hand the token to whatever it names. Every hop off the first request's origin
/// (scheme, host and port) loses `credentialHeaders`.
enum HTTPJSON {
    enum Failure: Error {
        case transport(Error)
        /// Any status outside 2xx; `0` for a response that is not HTTP at all.
        case status(Int)
    }

    /// Jira's and GitHub's `Authorization`, and GitLab's `PRIVATE-TOKEN`.
    static let credentialHeaders = ["Authorization", "PRIVATE-TOKEN"]

    static func send(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let guarded = CredentialGuard(origin: request.url)
        let (data, response) = try await transfer { try await session.data(for: request, delegate: guarded) }
        return (data, try check(response))
    }

    /// `send` for a body streamed to a temporary file, which the caller moves or deletes. A file
    /// that came with a failed status is deleted here.
    static func download(_ request: URLRequest, session: URLSession) async throws -> (URL, HTTPURLResponse) {
        let guarded = CredentialGuard(origin: request.url)
        let (file, response) = try await transfer { try await session.download(for: request, delegate: guarded) }
        do { return (file, try check(response)) }
        catch { try? FileManager.default.removeItem(at: file); throw error }
    }

    private static func transfer<Value>(_ body: () async throws -> Value) async throws -> Value {
        do { return try await body() }
        catch {
            // URLSession reports a cancelled task as `URLError.cancelled`.
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw Failure.transport(error)
        }
    }

    private static func check(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw Failure.status(0) }
        guard (200..<300).contains(http.statusCode) else { throw Failure.status(http.statusCode) }
        return http
    }
}

/// An element of a JSON list that may not decode, so one malformed entry drops only itself.
struct Lenient<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// Drops the credentials from a redirect that leaves the first request's origin.
private final class CredentialGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let origin: URL?
    init(origin: URL?) { self.origin = origin }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, let origin, url.isSameOrigin(as: origin) else {
            var request = request
            for header in HTTPJSON.credentialHeaders { request.setValue(nil, forHTTPHeaderField: header) }
            return request
        }
        return request
    }
}

extension URL {
    /// The host as DNS compares it: case-insensitively, a trailing dot ignored.
    var comparableHost: String? {
        guard var name = host?.lowercased() else { return nil }
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }

    /// The port as written, unless it is the scheme's own (443 for https, 80 for http), which
    /// names nothing the URL would not use anyway.
    var comparablePort: Int? {
        switch (scheme?.lowercased(), port) {
        case ("https", 443), ("http", 80): return nil
        default: return port
        }
    }

    func isSameOrigin(as other: URL) -> Bool {
        scheme?.lowercased() == other.scheme?.lowercased() && comparableHost == other.comparableHost && comparablePort == other.comparablePort
    }
}
