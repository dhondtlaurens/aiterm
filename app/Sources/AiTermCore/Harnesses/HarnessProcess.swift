import Foundation
import Synchronization

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

    /// Finding a CLI is a login shell, most of a second, and a Settings opening, a PI probe and
    /// an install each asked several times. A found path is kept for as long as it is still an
    /// executable; a missing CLI is looked for again every time, so one installed from a terminal
    /// shows up on the next probe.
    static func caching(find: @escaping @Sendable (String) -> String?,
                        isExecutable: @escaping @Sendable (String) -> Bool,
                        run: @escaping @Sendable (String, [String], [String: String], TimeInterval) throws -> ProcessOutput) -> HarnessCommandRunner {
        let cache = LocationCache()
        return HarnessCommandRunner(locate: { name in
            if let path = cache[name], isExecutable(path) { return path }
            let found = find(name)
            cache[name] = found
            return found
        }, run: run, forgetLocations: { cache.removeAll() })
    }

    public static let live = caching(find: { name in
        LoginShell.locate([name])?[name]
    }, isExecutable: LoginShell.isExecutableFile, run: { executable, arguments, overrides, timeout in
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
    })
}

private final class LocationCache: Sendable {
    private let paths = Mutex<[String: String]>([:])

    subscript(name: String) -> String? {
        get { paths.withLock { $0[name] } }
        set { paths.withLock { $0[name] = newValue } }
    }

    func removeAll() { paths.withLock { $0.removeAll() } }
}
