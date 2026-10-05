import Foundation
import AiTermCore

/// The environment that makes git behave the same on every machine. The developer's own
/// configuration changes what a fixture does — a `commit.gpgSign`, a `rebase.autoStash`, a
/// `core.hooksPath` or an `init.templateDir` there — and so do their identity and their home's
/// attributes and ignore files.
enum HermeticGit {
    /// No global, system or XDG configuration, a home with nothing in it, and an author and committer
    /// of our own, so a fixture commits without configuring one.
    static let environment: [String: String] = [
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        "HOME": ScratchHome.bare.path, "XDG_CONFIG_HOME": ScratchHome.bare.path,
        "GIT_AUTHOR_NAME": "AiTerm Tests", "GIT_AUTHOR_EMAIL": "tests@aiterm.invalid",
        "GIT_COMMITTER_NAME": "AiTerm Tests", "GIT_COMMITTER_EMAIL": "tests@aiterm.invalid",
    ]
}

extension GitRunner {
    /// A runner for tests: git with ``HermeticGit/environment`` on every command.
    static func hermetic() -> GitRunner { GitRunner(environment: HermeticGit.environment) }
}

extension GitRunning where Self == GitRunner {
    /// So a parameter typed `any GitRunning` takes `.hermetic()`.
    static func hermetic() -> GitRunner { GitRunner.hermetic() }
}
