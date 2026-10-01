import Foundation
@testable import AiTermCore

extension HarnessDriver {
    /// What the Driver check would read.
    var state: HarnessIntegrationState { probe().state }
}

extension GrokHooksFile {
    /// The hooks file's own state, whatever the status line says.
    static func state(home: URL, daemonPort: Int) -> HarnessIntegrationState {
        switch UserConfigFile(home: home, path).read() {
        case .missing: return .missing
        case .refused: return .unreadable
        case .present(let data): return state(of: data, daemonPort: daemonPort)
        }
    }
}
