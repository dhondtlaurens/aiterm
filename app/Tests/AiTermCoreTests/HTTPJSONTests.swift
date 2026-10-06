import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct HTTPJSONTests {
    struct Payload: Decodable, Equatable { var fullName: String }
    let url = URL(string: "https://example.com/thing")!

    @Test func aRequestCarriesItsHeadersAndTheClientsTimeout() {
        let request = HTTPJSON.request(url, headers: ["Accept": "application/json", "X-A": "1"])
        #expect(request.url == url)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-A") == "1")
        #expect(request.timeoutInterval == 15)
        #expect(HTTPJSON.request(url, headers: [:], timeout: 300).timeoutInterval == 300)
    }

    @Test func aURLKeepsItsPercentEncodedPathAndTakesItsQuery() throws {
        let built = try #require(HTTPJSON.url("https://gitlab.example/api/v4/projects/a%2Fb/merge_requests",
                                              query: [URLQueryItem(name: "search", value: "a b")]))
        #expect(built.absoluteString == "https://gitlab.example/api/v4/projects/a%2Fb/merge_requests?search=a%20b")
        #expect(HTTPJSON.url("https://example.com/x")?.absoluteString == "https://example.com/x")
        #expect(HTTPJSON.url("http://[::1") == nil)
    }

    @Test func decodeReadsSnakeCaseByDefaultAndReportsTheStatus() async throws {
        let stub = StubSession { _ in (200, Data(#"{"full_name":"octocat/hello"}"#.utf8)) }
        let (value, status) = try await HTTPJSON.decode(Payload.self, HTTPJSON.request(url, headers: [:]), session: stub.session)
        #expect(value == Payload(fullName: "octocat/hello"))
        #expect(status == 200)
    }

    @Test func decodeTakesTheDecoderItIsGiven() async throws {
        let stub = StubSession { _ in (200, Data(#"{"fullName":"x"}"#.utf8)) }
        let value = try await HTTPJSON.decode(Payload.self, HTTPJSON.request(url, headers: [:]), session: stub.session, decoder: JSONDecoder()).value
        #expect(value == Payload(fullName: "x"))
    }

    @Test(arguments: [401, 403, 404, 429, 500]) func aStatusOutsideTwoHundredsFails(status: Int) async {
        let stub = StubSession { _ in (status, Data(#"{"full_name":"x"}"#.utf8)) }
        await #expect {
            _ = try await HTTPJSON.decode(Payload.self, HTTPJSON.request(url, headers: [:]), session: stub.session)
        } throws: { error in
            if case HTTPJSON.Failure.status(status) = error { return true } else { return false }
        }
    }

    @Test func aBodyThatIsNotThePayloadFailsAsUndecodableWithItsStatus() async {
        let stub = StubSession { _ in (200, Data(#"{"other":1}"#.utf8)) }
        await #expect {
            _ = try await HTTPJSON.decode(Payload.self, HTTPJSON.request(url, headers: [:]), session: stub.session)
        } throws: { error in
            if case HTTPJSON.Failure.undecodable(status: 200) = error { return true } else { return false }
        }
    }

    @Test func mappingTurnsEachFailureIntoTheClientsOwn() async {
        struct Mine: Error, Equatable { var text: String }
        let stub = StubSession { _ in (418, Data()) }
        await #expect(throws: Mine(text: "418")) {
            _ = try await HTTPJSON.decode(Payload.self, HTTPJSON.request(url, headers: [:]), session: stub.session) { failure -> Mine in
                if case .status(let status) = failure { return Mine(text: "\(status)") }
                return Mine(text: "other")
            }
        }
    }

    @Test func aCancelledRequestStaysCancellationThroughMapping() async {
        let stub = StubSession { _ in (200, Data(#"{"full_name":"x"}"#.utf8)) }
        let request = HTTPJSON.request(url, headers: [:])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await HTTPJSON.decode(Payload.self, request, session: stub.session) { _ -> any Error in fatalError("a cancellation is not a failure") }
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
