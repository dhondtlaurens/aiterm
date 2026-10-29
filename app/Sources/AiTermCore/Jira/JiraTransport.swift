import Foundation

extension JiraClient {
    /// Sends already encoded JSON, preserving the caller's encoder. Search uses read errors;
    /// writes keep Jira's refusal details, including for an empty successful response.
    func send(method: String, path: String, json: Data, write: Bool = true) async throws -> Data {
        var req = request(path: path)
        req.httpMethod = method
        req.httpBody = json
        if write { return try await writeSend(req) }
        do { return try await HTTPJSON.send(req, session: session).0 }
        catch let failure as HTTPJSON.Failure { throw Self.error(for: failure) }
    }

    /// Jira's own keys are camelCase. Read failures retain the shared transport's diagnostic;
    /// write responses have always mapped a decoding failure without logging it.
    func decode<Response: Decodable>(_ type: Response.Type, data: Data, reading path: String? = nil) throws -> Response {
        do { return try JSONDecoder().decode(type, from: data) }
        catch {
            if let path {
                Log.network.failed("Reading \(config.siteURL.appendingPathComponent(path).path) as \(Response.self)", error)
            }
            throw JiraError.decoding
        }
    }

    /// Reads needed to prepare a write retain write refusal details as well.
    func writeDecode<Response: Decodable>(_ type: Response.Type, _ request: URLRequest) async throws -> Response {
        try decode(type, data: await writeSend(request))
    }

    /// A refusal keeps Jira's own words: its 400s and 404s say which field or which ticket.
    private func writeSend(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await HTTPJSON.sendUnchecked(request, session: session)
            guard (200..<300).contains(response.statusCode) else { throw Self.writeError(status: response.statusCode, body: data) }
            return data
        } catch let failure as HTTPJSON.Failure { throw Self.error(for: failure) }
    }
}
