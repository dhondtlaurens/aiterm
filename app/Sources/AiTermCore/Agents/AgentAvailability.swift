import Foundation

/// Spec 8: the New Task sheet must not offer an agent whose CLI is not installed — a task created
/// for a missing agent opens a window whose first line is "command not found".
///
/// Installed means the `LoginShellLocator` finds it: the same answer Settings' harness cards go
/// by, from the same locator, so the two never disagree about an agent. It asks the login shell
/// because a GUI app inherits launchd's minimal `PATH`, not the one `~/.zprofile` builds: `claude`
/// and `codex` live in `~/.local/bin`, Homebrew or a version manager's shims. The launch's lookup
/// of Python asks the same shell, and what it finds is where Settings and PI's catalogue then
/// look, without a shell of their own. `locator` is injectable so the unit test never shells out.
public enum AgentAvailability {
    /// `nil` when the login shell itself failed or ran out of time: that says nothing about which
    /// agents exist, and an empty set would block every New Task sheet until the app is relaunched.
    public static func installed(locator: LoginShellLocator = .shared) -> Set<AgentKind>? {
        locator.current().map { Set($0.executables.keys.compactMap(AgentKind.init)) }
    }

    /// `preferred` when it is installed, else the first agent that is. An empty `available` is an
    /// availability not known yet, which rules nothing out.
    public static func agent(preferring preferred: AgentKind, available: Set<AgentKind>) -> AgentKind {
        guard !available.isEmpty, !available.contains(preferred) else { return preferred }
        return AgentKind.allCases.first(where: available.contains) ?? preferred
    }
}
