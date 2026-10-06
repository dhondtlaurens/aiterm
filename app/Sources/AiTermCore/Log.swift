import Foundation
import os

/// The app's own log, one `Logger` per part of it, read in Console.app or with
/// `log stream --predicate 'subsystem == "com.laurensdhondt.aiterm"'`. It is where a failure the
/// app goes on without is found again: one the person must act on is also said in a banner, an
/// alert or a toast, and this keeps what that sentence leaves out — git's own words, the helper's
/// raw message. The helper process keeps its own log, `aitermd.log`.
///
/// Every value is logged `.public`, by design: a line that reads `<private>` in Console.app is no
/// use to the person trying to find out what went wrong. So a caller never puts in one what must
/// not be read there — a token or password, the text of a prompt, a remote's URL (which can carry
/// a token): it names the project by its path, the request by its method, the branch by its name.
public enum Log {
    public static let subsystem = "com.laurensdhondt.aiterm"
    /// The socket to the helper: requests that failed, events that could not be read, reconnects.
    public static let daemon = Logger(subsystem: subsystem, category: "daemon")
    /// git run for a step the caller goes on without: a best-effort fetch, unlock or prune.
    public static let git = Logger(subsystem: subsystem, category: "git")
    /// The saved workspace and the projects in it.
    public static let workspace = Logger(subsystem: subsystem, category: "workspace")
    /// The agents' own files AiTerm reads or writes: hooks, settings, status lines, model catalogues.
    public static let harness = Logger(subsystem: subsystem, category: "harness")
    /// The REST services: Jira, GitLab, GitHub and the release feeds.
    public static let network = Logger(subsystem: subsystem, category: "network")
    /// Checking for, downloading and installing a release.
    public static let updates = Logger(subsystem: subsystem, category: "updates")
    /// What the person was told, or would have been: banners held back, apps that would not open.
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}

extension Logger {
    /// `work`'s value, or `nil` once its failure is logged as `what` failing: for a step the caller
    /// goes on without, where `try?` would leave no trace of why.
    @discardableResult
    public func attempt<Value>(_ what: @autoclosure () -> String, level: OSLogType = .error,
                               _ work: () throws -> Value) -> Value? {
        do { return try work() } catch {
            failed(what(), error, level: level)
            return nil
        }
    }

    /// `attempt` for work that awaits, run on the caller's actor.
    @discardableResult
    public func attempt<Value>(_ what: @autoclosure () -> String, level: OSLogType = .error,
                               isolation: isolated (any Actor)? = #isolation,
                               _ work: () async throws -> Value) async -> Value? {
        do { return try await work() } catch {
            failed(what(), error, level: level)
            return nil
        }
    }

    /// `what` failed with `error`, logged in one line: a git failure with the command and its own
    /// words, which the banner's sentence (`GitError.sentence`) tidies away.
    public func failed(_ what: String, _ error: Error, level: OSLogType = .error) {
        let detail = (error as? GitError).map { git in
            "git \(git.args.joined(separator: " ")) exited \(git.code)\(git.timedOut ? ", timed out" : ""): \(git.stderr)"
        } ?? String(describing: error)
        log(level: level, "\(what, privacy: .public) failed: \(detail, privacy: .public)")
    }
}
