import Foundation
@testable import AiTermCore

extension HarnessDriver {
    /// What the Driver check would read.
    var state: HarnessIntegrationState { probe().state }
}
