import Foundation

public enum HarnessProcessError: Error, Equatable, LocalizedError {
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message): return message
        }
    }
}

/// How the harness code finds and runs an agent CLI — injectable so the Settings and catalogue
/// tests never launch one.
public struct HarnessCommandRunner: Sendable {
    public var locate: @Sendable (String) -> String?
    public var run: @Sendable (_ executable: String, _ arguments: [String],
                              _ environment: [String: String], _ timeout: TimeInterval) throws -> ProcessOutput
    /// Drops whatever `locate` remembers, once an install may have moved a CLI.
    public var forgetLocations: @Sendable () -> Void

    public init(locate: @escaping @Sendable (String) -> String?,
                run: @escaping @Sendable (String, [String], [String: String], TimeInterval) throws -> ProcessOutput,
                forgetLocations: @escaping @Sendable () -> Void = {}) {
        self.locate = locate
        self.run = run
        self.forgetLocations = forgetLocations
    }

    /// CLIs found through `locator`, which keeps what it found, and run with their `bin` on the
    /// `PATH`.
    public init(locator: LoginShellLocator) {
        self.init(locate: { locator.locate($0) }, run: Self.launch, forgetLocations: { locator.forget() })
    }

    /// The app's: CLIs found where the launch's probe found them, through the shared locator.
    public static let live = HarnessCommandRunner(locator: .shared)

    /// A machine with no agent CLI on it, for what renders or tests a catalogue without launching
    /// one: nothing is found and nothing starts.
    public static let nothingInstalled = HarnessCommandRunner(locate: { _ in nil }, run: { executable, _, _, _ in
        throw HarnessProcessError.launchFailed("\(executable) is not installed.")
    })

    private static let launch: @Sendable (String, [String], [String: String], TimeInterval) throws -> ProcessOutput = {
        executable, arguments, overrides, timeout in
        var environment = ProcessRunner.inheritedEnvironment
        for (key, value) in overrides { environment[key] = value }
        // An npm CLI such as PI is a `#!/usr/bin/env node` script, and an app opened from the
        // Dock has launchd's `PATH`, with no Homebrew or nvm in it. npm links the CLI into the
        // same `bin` as the node that installed it, so that directory is where `env` must look.
        let binDirectory = (executable as NSString).deletingLastPathComponent
        environment["PATH"] = [binDirectory, environment["PATH"]].compactMap { $0 }.joined(separator: ":")
        do {
            return try ProcessRunner.run(URL(fileURLWithPath: executable), arguments, environment: environment, timeout: timeout)
        } catch {
            throw HarnessProcessError.launchFailed(error.localizedDescription)
        }
    }
}
