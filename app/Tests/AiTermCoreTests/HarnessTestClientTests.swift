import Foundation
import Testing
@testable import AiTermCore

@Suite struct HarnessTestClientTests {
    @Test func claudeAndCodexTestsRequireMatchingDaemonAcknowledgement() async throws {
        let transport = HarnessTestTransport { url, body, headers in
            #expect(headers["Content-Type"] == "application/json")
            #expect(headers["X-AiTerm-Hook"] == "1")
            #expect(["/hook/claude", "/hook/codex", "/hook/grok"].contains(url.path))
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            if let id = object["_aiterm_daemon_test_id"] {
                return try JSONSerialization.data(withJSONObject: ["ok": true, "daemonTestId": id])
            }
            let id = try #require(object["_aiterm_test_id"])
            return try JSONSerialization.data(withJSONObject: ["ok": true, "testId": id])
        }
        let client = HarnessTestClient(transport: transport)
        let claude = await client.testHTTP(endpoint: Harness.claude.hookEndpoint)
        let codex = await client.testHTTP(endpoint: Harness.codex.hookEndpoint)
        let grok = await client.testHTTP(endpoint: Harness.grok.hookEndpoint)
        #expect(claude.passed)
        #expect(codex.passed)
        #expect(grok.passed)
        #expect(claude.checks.map(\.id) == [.daemon, .delivery])
        #expect(claude.checks.map(\.passed) == [true, true])
    }

    @Test func httpTestRejectsWrongAcknowledgementAndTransportFailure() async {
        let wrong = HarnessTestTransport { _, body, _ in
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
            if let id = object?["_aiterm_daemon_test_id"] {
                return try JSONSerialization.data(withJSONObject: ["ok": true, "daemonTestId": id])
            }
            return try JSONSerialization.data(withJSONObject: ["ok": true, "testId": "someone-else"])
        }
        let wrongResult = await HarnessTestClient(transport: wrong).testHTTP(endpoint: Harness.claude.hookEndpoint)
        #expect(!wrongResult.passed)
        #expect(wrongResult.explanation == "AiTerm did not receive the test event.")
        #expect(wrongResult.checks.map(\.passed) == [true, false])

        let failedResult = await HarnessTestClient(transport: .failing).testHTTP(endpoint: Harness.codex.hookEndpoint)
        #expect(!failedResult.passed)
        #expect(failedResult.explanation == "AiTerm’s helper is unavailable.")
        #expect(failedResult.checks.map(\.id) == [.daemon, .delivery])
        #expect(failedResult.checks.map(\.passed) == [false, false])
    }

    @Test func piTestRequiresTheExtensionMarkerAndTerminatesOnTimeout() async {
        let runner = HarnessCommandRunner(locate: { _ in "/usr/local/bin/pi" }, run: { _, arguments, environment, timeout in
            #expect(arguments == ["--offline", "--mode", "rpc", "--no-session", "--no-extensions", "--extension", "/tmp/aiterm-status.ts"])
            #expect(environment["PI_OFFLINE"] == "1")
            #expect(environment["AITERM_INTEGRATION_TEST"] != nil)
            #expect(timeout == 5)
            return ProcessOutput(status: 15, stdout: "", stderr: "", timedOut: true)
        })
        let result = await HarnessTestClient(runner: runner, transport: daemonAvailable)
            .testPi(extensionPath: "/tmp/aiterm-status.ts")
        #expect(!result.passed)
        #expect(result.explanation == "PI did not load the driver in time.")
    }

    @Test func piTestRequiresZeroExitAndTheExactCorrelationMarker() async {
        let success = HarnessCommandRunner(locate: { _ in "/usr/local/bin/pi" }, run: { _, _, environment, _ in
            let id = environment["AITERM_INTEGRATION_TEST"] ?? ""
            return ProcessOutput(status: 0, stdout: "", stderr: "noise\nAITERM_INTEGRATION_TEST_OK=\(id)\n", timedOut: false)
        })
        #expect((await HarnessTestClient(runner: success, transport: daemonAvailable)
            .testPi(extensionPath: "/tmp/aiterm-status.ts")).passed)

        let missingMarker = HarnessCommandRunner(locate: { _ in "/usr/local/bin/pi" }, run: { _, _, _, _ in
            ProcessOutput(status: 0, stdout: "", stderr: "AITERM_INTEGRATION_TEST_OK=wrong", timedOut: false)
        })
        let missing = await HarnessTestClient(runner: missingMarker, transport: daemonAvailable)
            .testPi(extensionPath: "/tmp/aiterm-status.ts")
        #expect(!missing.passed)
        #expect(missing.explanation == "PI did not confirm the driver.")

        let failedExit = HarnessCommandRunner(locate: { _ in "/usr/local/bin/pi" }, run: { _, _, environment, _ in
            let id = environment["AITERM_INTEGRATION_TEST"] ?? ""
            return ProcessOutput(status: 1, stdout: "", stderr: "AITERM_INTEGRATION_TEST_OK=\(id)", timedOut: false)
        })
        #expect(!(await HarnessTestClient(runner: failedExit, transport: daemonAvailable)
            .testPi(extensionPath: "/tmp/aiterm-status.ts")).passed)
    }
}

private let daemonAvailable = HarnessTestTransport { _, body, _ in
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
    let id = try #require(object["_aiterm_daemon_test_id"])
    return try JSONSerialization.data(withJSONObject: ["ok": true, "daemonTestId": id])
}
