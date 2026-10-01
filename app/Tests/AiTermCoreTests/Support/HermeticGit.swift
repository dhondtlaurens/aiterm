import Foundation
@testable import AiTermCore

extension GitRunner {
    /// git without the developer's global or system configuration: a `rebase.autoStash`, a
    /// `commit.gpgSign` or a `rebase.rebaseMerges` there would change what a fixture does.
    static let hermeticEnvironment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]

    /// A runner for tests: `hermeticEnvironment` on every command.
    static func hermetic() -> GitRunner { GitRunner(environment: hermeticEnvironment) }
}
