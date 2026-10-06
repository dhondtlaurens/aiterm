import Testing
import Foundation
import Synchronization
@testable import AiTermCore

@Suite struct AgentAvailabilityTests {
    /// What `installed` says when the login shell prints `output`.
    private func installed(_ output: String?) -> Set<AgentKind>? {
        AgentAvailability.installed(locator: LoginShellLocator(shell: { _ in output }))
    }

    /// One login shell answers for every agent: each one costs the better part of a second.
    @Test func testEveryAgentIsAskedAboutInOneLoginShell() {
        let asked = Mutex<[String]>([])
        let locator = LoginShellLocator(shell: { command in
            asked.withLock { $0.append(command) }
            return "claude\t/bin/sh\nclaude\t/bin/sh\ncodex\t\ncodex\t\npi\t/bin/sh\npi\t/bin/sh\n"
        })
        let found = AgentAvailability.installed(locator: locator)
        #expect(found == [.claude, .pi])
        #expect(asked.withLock { $0 } == [locator.query])
        #expect(locator.query.hasPrefix(LoginShell.locateQuery(AgentKind.allCases.map(\.rawValue))))
        #expect(locator.query.contains("claude codex grok pi"))
    }

    /// The New Task sheet and Settings ask the same locator, so an agent installed as an alias is
    /// offered in one exactly when the other can run it.
    @Test func testAnAliasedAgentIsInstalledWhereTheHarnessCanRunIt() {
        #expect(installed("claude\talias claude=/bin/sh\nclaude\t\n") == [.claude])
        #expect(installed("codex\tcodex\ncodex\t\n") == [],
                "a function that wraps no file on the PATH is nothing the harness can run")
    }

    /// A shell that answered but printed no agent found none.
    @Test func testEmptyOrForeignOutputIsNotInstalled() {
        #expect(installed("") == [])
        #expect(installed("  \n") == [])
        #expect(installed("Welcome to zsh\n") == [])
    }

    /// A shell that failed or timed out found out nothing, which is not "none installed".
    @Test func testAFailedShellAnswersUnknown() {
        #expect(installed(nil) == nil)
    }

    /// A remembered agent that is no longer installed gives way to one that is.
    @Test func testTheRememberedAgentFallsBackToAnInstalledOne() {
        #expect(AgentAvailability.agent(preferring: .codex, available: [.codex, .pi]) == .codex)
        #expect(AgentAvailability.agent(preferring: .codex, available: [.pi, .claude]) == .claude)
        #expect(AgentAvailability.agent(preferring: .codex, available: []) == .codex, "not known yet rules nothing out")
    }
}
