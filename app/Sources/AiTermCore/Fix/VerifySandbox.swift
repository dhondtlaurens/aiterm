import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Runs a proposal's `verify` command in the clone under `sandbox-exec`. The profile denies
/// network (unix sockets included), writes outside the clone and the per-user temporary directory,
/// and the lookups of LaunchServices, AppleEvents and the pasteboard — through those a command
/// could start an app (`open`) that runs unconfined. It does not deny everything: `defaults`
/// writes go through `cfprefsd` and remain possible. Through the login shell, so `pnpm` and
/// friends are on `PATH` as in a terminal. Never run unconfined: without `sandbox-exec` there is
/// no `verify` (spec §11.5). `/private/tmp` is deliberately not writable (spikes: it would let the
/// command write outside the clone), and the profile is a string, so every path is escaped.
enum VerifySandbox {
    static let executable = "/usr/bin/sandbox-exec"
    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: executable) }

    /// The path as the kernel sees it, which is what a sandbox profile matches: `/private/var/…`,
    /// where Foundation's `resolvingSymlinksInPath` deliberately says `/var/…` and so would leave
    /// the profile naming a path nothing ever has. A path that does not exist is returned as given.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func profile(writableRoot: String) -> String {
        func quoted(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let temporary = realPath(NSTemporaryDirectory())
        return """
        (version 1)(allow default)(deny network*)(deny file-write*)
        (deny mach-lookup (global-name "com.apple.coreservices.launchservicesd") (global-name "com.apple.lsd.mapdb")
          (global-name "com.apple.lsd.modifydb") (global-name "com.apple.coreservices.appleevents") (global-name "com.apple.pasteboard.1"))
        (allow file-write* (subpath \(quoted(writableRoot))) (subpath \(quoted(temporary)))
          (literal "/dev/null") (literal "/dev/tty") (regex #"^/dev/fd/"))
        """
    }

    /// Returns when `command` exits 0. Anything else — a nonzero status, a timeout (status -1), a
    /// failure to start — is `verifyFailed`. Where `sandbox-exec` is missing, nothing runs and
    /// nothing is claimed: callers check `isAvailable` and offer no `verify` then.
    static func run(_ command: String, in clone: String, timeout: Duration) async throws(FixRefusal) {
        guard isAvailable else { return }
        let output: ProcessOutput
        do {
            output = try await AgentProcess.run(executable, ["-p", profile(writableRoot: realPath(clone)), "/bin/zsh", "-lc", command],
                                                environment: [:], in: clone, timeout: timeout)
        } catch {
            throw .verifyFailed(command, status: -1)
        }
        guard !output.timedOut, output.status == 0 else { throw .verifyFailed(command, status: output.timedOut ? -1 : output.status) }
    }
}
