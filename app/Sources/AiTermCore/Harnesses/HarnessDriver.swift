import Foundation

/// One harness's driver — the hooks, extension or status line AiTerm writes so the agent reports
/// its state — in the one shape `HarnessService` drives all four by. A driver is built from what
/// it writes to (`home`, the daemon's port, the bundled resource it installs) and reads its files
/// once per probe.
protocol HarnessDriver: Sendable {
    /// The driver's state, read off its files: why it is not current, and any check the card
    /// shows after the Driver check.
    func probe() -> DriverProbe
    /// Writes the driver, or throws `HarnessDriverError` having written nothing: a file AiTerm
    /// must not replace, or cannot read, stops the whole install before any file is touched.
    func install() throws
    /// Sends a synthetic event the way the installed driver would.
    func test(with client: HarnessTestClient) async -> HarnessTestResult
}

struct DriverProbe: Equatable, Sendable {
    var state: HarnessIntegrationState
    /// The Driver check's explanation; `nil` when it passes.
    var explanation: String?
    /// Checks after the Driver check, such as Grok's Context.
    var checks: [HarnessCheck] = []

    /// A state every driver explains the same way.
    init(_ state: HarnessIntegrationState, checks: [HarnessCheck] = []) {
        self.state = state
        self.checks = checks
        switch state {
        case .current: explanation = nil
        case .missing: explanation = "Driver is not installed."
        case .outdated: explanation = "Driver is out of date."
        case .invalidOwned: explanation = "AiTerm’s driver is invalid."
        case .foreign: explanation = "A different file occupies the driver’s path."
        case .unreadable: explanation = "The driver cannot be read."
        case .resourceUnavailable: explanation = "The bundled driver is unavailable."
        case .notChecked: explanation = "Driver was not checked."
        }
    }

    init(state: HarnessIntegrationState, explanation: String?) {
        self.state = state
        self.explanation = explanation
    }

    /// A file at `file`'s path that AiTerm did not write.
    static func foreign(_ file: UserConfigFile) -> DriverProbe {
        DriverProbe(state: .foreign, explanation: "A different file occupies \(file.displayPath).")
    }

    /// A file that cannot be read, or merged into: `reason` finishes "it …".
    static func refused(_ file: UserConfigFile, _ reason: String) -> DriverProbe {
        DriverProbe(state: .unreadable, explanation: "\(file.displayPath) \(reason).")
    }
}
