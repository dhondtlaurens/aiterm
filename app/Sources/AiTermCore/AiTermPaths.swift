import Foundation

/// The one place that knows where AiTerm keeps its files and which port the agent hooks post to.
/// Both the app and the daemon supervisor read these, so a change here cannot leave the hook
/// installer and the daemon arguing about a port, or the log and the socket in different folders.
public enum AiTermPaths {
    /// Hook HTTP receiver port. The drivers install it: the agents' hook URLs
    /// carry it, PI's extension is written with it, and Claude's status-line shim reads it from
    /// `hookPortURL` (`ShimPort`). The supervisor passes it to `aitermd run --hook-port`.
    public static let hookPort = 47821

    /// AiTerm's folder in `home`'s Application Support: state, the helper's socket and log, and the
    /// small files the status-line shim reads. The shim spells the same path in shell
    /// (`StatusLineShimTests` pins that it does).
    public static func supportDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/AiTerm")
    }

    /// The port the status-line shim posts to, one line of digits: the shim runs on every tick of
    /// Claude Code's status line and reads it with a shell builtin.
    public static func hookPortURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(home: home).appendingPathComponent("hook-port")
    }

    /// The delivery check's verdicts (`daemon/tools/delivery_check.py`), which the helper reads on
    /// every delivery (`delivery.POLICY_PATH`) and Settings › Agents on every card.
    public static func deliveryPolicyURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(home: home).appendingPathComponent("delivery-policy.json")
    }

    /// The command of the user's own status line for `agent`, which its shim runs: one file per agent,
    /// so installing one agent's shim never touches another's record. Claude's keeps the name it had.
    public static func statusLineOriginalURL(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                             agent: AgentKind = .claude) -> URL {
        supportDirectory(home: home).appendingPathComponent(
            agent == .claude ? "statusline-original.cmd" : "statusline-original-\(agent.rawValue).cmd")
    }

    public static var socketPath: String { supportDirectory().appendingPathComponent("aitermd.sock").path }
    public static var daemonLogURL: URL { supportDirectory().appendingPathComponent("aitermd.log") }

    /// Where a downloaded update is unpacked and verified, and where the replaced app waits until
    /// the new one launches. Caches, because every file in it is disposable: launch deletes it.
    public static var updatesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.laurensdhondt.aiterm/Updates")
    }
}
