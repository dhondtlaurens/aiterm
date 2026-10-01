import Testing
import Foundation
@testable import AiTermCore

@Suite struct AgentAvailabilityTests {
    /// One login shell answers for every agent: each one costs the better part of a second.
    @Test func testEveryAgentIsAskedAboutInOneLoginShell() {
        var asked: [String] = []
        let found = AgentAvailability.installed(runner: { command in
            asked.append(command)
            return "claude\t/bin/sh\nclaude\t/bin/sh\ncodex\t\ncodex\t\npi\t/bin/sh\npi\t/bin/sh\n"
        })
        let query = LoginShell.locateQuery(AgentKind.allCases.map(\.rawValue))
        #expect(found == [.claude, .pi])
        #expect(asked == [query])
        #expect(query.contains("claude codex grok pi"))
    }

    /// The New Task sheet and Settings ask the same locator, so an agent installed as an alias is
    /// offered in one exactly when the other can run it.
    @Test func testAnAliasedAgentIsInstalledWhereTheHarnessCanRunIt() {
        #expect(AgentAvailability.installed(runner: { _ in "claude\talias claude=/bin/sh\nclaude\t\n" }) == [.claude])
        #expect(AgentAvailability.installed(runner: { _ in "codex\tcodex\ncodex\t\n" }) == [],
                "a function that wraps no file on the PATH is nothing the harness can run")
    }

    /// A shell that answered but printed no agent found none.
    @Test func testEmptyOrForeignOutputIsNotInstalled() {
        #expect(AgentAvailability.installed(runner: { _ in "" }) == [])
        #expect(AgentAvailability.installed(runner: { _ in "  \n" }) == [])
        #expect(AgentAvailability.installed(runner: { _ in "Welcome to zsh\n" }) == [])
    }

    /// A shell that failed or timed out found out nothing, which is not "none installed".
    @Test func testAFailedShellAnswersUnknown() {
        #expect(AgentAvailability.installed(runner: { _ in nil }) == nil)
    }

    /// A remembered agent that is no longer installed gives way to one that is.
    @Test func testTheRememberedAgentFallsBackToAnInstalledOne() {
        #expect(AgentAvailability.agent(preferring: .codex, available: [.codex, .pi]) == .codex)
        #expect(AgentAvailability.agent(preferring: .codex, available: [.pi, .claude]) == .claude)
        #expect(AgentAvailability.agent(preferring: .codex, available: []) == .codex, "not known yet rules nothing out")
    }
}
