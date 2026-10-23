import Foundation

public struct HarnessTestTransport: Sendable {
    public var post: @Sendable (_ url: URL, _ body: Data,
                                _ headers: [String: String]) async throws -> Data

    public init(post: @escaping @Sendable (URL, Data, [String: String]) async throws -> Data) {
        self.post = post
    }

    public static let live = HarnessTestTransport { url, body, headers in
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 2
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

/// The daemon and delivery checks a Test adds to a card.
public struct HarnessTestResult: Equatable, Sendable {
    public var checks: [HarnessCheck]

    public init(checks: [HarnessCheck]) { self.checks = checks }
}

public struct HarnessTestClient: Sendable {
    private let runner: HarnessCommandRunner
    private let transport: HarnessTestTransport
    private let daemonPort: Int

    public init(runner: HarnessCommandRunner = .live,
                transport: HarnessTestTransport = .live,
                daemonPort: Int = AiTermPaths.hookPort) {
        self.runner = runner
        self.transport = transport
        self.daemonPort = daemonPort
    }

    /// Posts a test event to `endpoint`, the daemon's path for a driver's events, as an HTTP
    /// driver's hook would.
    public func testHTTP(endpoint: String) async -> HarnessTestResult {
        guard let url = URL(string: "http://127.0.0.1:\(daemonPort)" + endpoint) else {
            return HarnessTestResult(checks: [deliveryCheck(passed: false, explanation: "AiTerm did not receive the test event.")])
        }
        let daemon = await daemonCheck(url: url)
        guard daemon.passed else { return HarnessTestResult(checks: [daemon, skippedDeliveryCheck()]) }
        let passed = await roundTrip(url: url, requestKey: "_aiterm_test_id", responseKey: "testId")
        return HarnessTestResult(checks: [daemon, deliveryCheck(passed: passed,
            explanation: passed ? nil : "AiTerm did not receive the test event.")])
    }

    public func testPi(extensionPath: String) async -> HarnessTestResult {
        guard let url = URL(string: Harness.pi.hookURL(port: daemonPort)) else {
            return HarnessTestResult(checks: [deliveryCheck(passed: false, explanation: "AiTerm did not receive the test event.")])
        }
        let daemon = await daemonCheck(url: url)
        guard daemon.passed else { return HarnessTestResult(checks: [daemon, skippedDeliveryCheck()]) }
        // Both launch processes, which the cooperative pool must not wait on.
        let runner = self.runner
        guard let executable = await BackgroundWork.run({ runner.locate(Harness.pi.executable) }) else {
            return HarnessTestResult(checks: [daemon, deliveryCheck(passed: false, explanation: "PI CLI is unavailable.")])
        }
        let id = UUID().uuidString
        let processResult: ProcessOutput
        do {
            processResult = try await BackgroundWork.run {
                try runner.run(executable, [
                    "--offline", "--mode", "rpc", "--no-session", "--no-extensions",
                    "--extension", extensionPath,
                ], ["PI_OFFLINE": "1", "AITERM_INTEGRATION_TEST": id], 5)
            }
        } catch {
            return HarnessTestResult(checks: [daemon, deliveryCheck(passed: false,
                                                  explanation: "PI couldn’t start the driver.")])
        }
        if processResult.timedOut {
            return HarnessTestResult(checks: [daemon, deliveryCheck(passed: false,
                                                       explanation: "PI did not load the driver in time.")])
        }
        let marker = "AITERM_INTEGRATION_TEST_OK=\(id)"
        let confirmed = processResult.stderr.split(whereSeparator: \Character.isNewline).contains { $0 == marker }
        guard processResult.status == 0, confirmed else {
            return HarnessTestResult(checks: [daemon, deliveryCheck(passed: false,
                                                       explanation: "PI did not confirm the driver.")])
        }
        return HarnessTestResult(checks: [daemon, deliveryCheck(passed: true, explanation: nil)])
    }

    private func daemonCheck(url: URL) async -> HarnessCheck {
        let passed = await roundTrip(url: url, requestKey: "_aiterm_daemon_test_id", responseKey: "daemonTestId")
        return HarnessCheck(.daemon, passed: passed, explanation: passed ? nil : "AiTerm’s helper is unavailable.")
    }

    private func roundTrip(url: URL, requestKey: String, responseKey: String) async -> Bool {
        let id = UUID().uuidString
        do {
            let body = try JSONSerialization.data(withJSONObject: [requestKey: id])
            let data = try await transport.post(url, body, ["Content-Type": "application/json", "X-AiTerm-Hook": "1"])
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return object?["ok"] as? Bool == true && object?[responseKey] as? String == id
        } catch { return false }
    }

    private func deliveryCheck(passed: Bool, explanation: String?) -> HarnessCheck {
        HarnessCheck(.delivery, passed: passed, explanation: explanation)
    }

    private func skippedDeliveryCheck() -> HarnessCheck {
        deliveryCheck(passed: false, explanation: "Status delivery was not tested because AiTerm’s helper is unavailable.")
    }
}
