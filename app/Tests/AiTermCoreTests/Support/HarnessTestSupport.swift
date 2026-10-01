import Foundation
@testable import AiTermCore

extension HarnessTestResult {
    var passed: Bool { checks.allSatisfy(\.passed) }
    /// What the card would say: the first failed check's explanation.
    var explanation: String? { checks.first { !$0.passed }?.explanation }
}

extension HarnessTestTransport {
    /// A daemon that never answers.
    static let failing = HarnessTestTransport { _, _, _ in throw URLError(.cannotConnectToHost) }
}
