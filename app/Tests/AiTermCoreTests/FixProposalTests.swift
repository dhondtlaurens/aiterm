import Testing
import Foundation
@testable import AiTermCore

struct FixProposalTests {
    let request = FixRequest(title: "Couldn’t create the review.", reason: "Rebasing hit a conflict.", detail: "CONFLICT (content): config.ts",
                             projectPath: "/p", branch: "feat/x", recreateRebase: true, retry: .createReview)
    let local: Set<String> = ["aaaaaaa1111111111111111111111111111111aa", "bbbbbbb2222222222222222222222222222222bb"]

    private func answer(outcome: String? = "fix", headline: String? = "Your 2 local commits are an older copy.", why: String? = "Force-pushed.",
                        steps: [String]? = ["Keep a backup", "Point the branch at origin’s"], moves: [String]? = ["feat/x"],
                        drops: [String]? = [], verify: String? = nil, reason: String? = nil) -> FixLookAnswer {
        FixLookAnswer(outcome: outcome, headline: headline, why: why, steps: steps, moves: moves, drops: drops, verify: verify, reason: reason)
    }

    @Test func aGoodAnswerIsAProposal() throws {
        let look = try FixLook(validating: answer(drops: [local.first!]), request: request, localOnly: local, agent: .claude)
        guard case .fix(let proposal) = look else { Issue.record("expected a proposal"); return }
        #expect(proposal.steps.count == 2)
        #expect(proposal.drops == [local.first!])
    }

    @Test func noneCarriesItsReason() throws {
        #expect(try FixLook(validating: answer(outcome: "none", reason: "A product decision."), request: request, localOnly: local, agent: .claude)
                == .none("A product decision."))
    }

    /// One answer that breaks the contract, named for the test's output. A named Sendable struct,
    /// because a tuple of closures does not satisfy `@Test(arguments:)` under Swift 6.
    struct OutOfContract: Sendable {
        let name: String
        let change: @Sendable (inout FixLookAnswer) -> Void
        init(_ name: String, change: @escaping @Sendable (inout FixLookAnswer) -> Void) {
            self.name = name; self.change = change
        }
    }

    @Test(arguments: [
        OutOfContract("a branch it may not move") { $0.moves = ["main"] },
        OutOfContract("no steps") { $0.steps = [] },
        OutOfContract("four steps") { $0.steps = ["1", "2", "3", "4"] },
        OutOfContract("a headline past 90") { $0.headline = String(repeating: "x", count: 91) },
        OutOfContract("a why past 300") { $0.why = String(repeating: "x", count: 301) },
        OutOfContract("a drop that is not a local commit") { $0.drops = ["ccccccc"] },
        OutOfContract("no outcome") { $0.outcome = nil },
        OutOfContract("a shell operator in verify") { $0.verify = "pnpm typecheck && curl x" },
        OutOfContract("a subshell in verify") { $0.verify = "pnpm $(echo typecheck)" },
        OutOfContract("a glob in verify") { $0.verify = "pnpm test *" },
        OutOfContract("a subshell paren in verify") { $0.verify = "(pnpm typecheck)" },
        OutOfContract("a bare glob in verify") { $0.verify = "pnpm *" },
        OutOfContract("a prefix rule in verify") { $0.verify = "pnpm:*" },
        OutOfContract("a newline in verify") { $0.verify = "pnpm typecheck\nrm -rf ~" },
    ])
    func anAnswerOutOfContractIsNoPlan(_ bad: OutOfContract) {
        var broken = answer()
        bad.change(&broken)
        #expect(throws: FixRefusal.unreadableAnswer(.claude), "\(bad.name)") {
            try FixLook(validating: broken, request: request, localOnly: local, agent: .claude)
        }
    }

    /// A plain command passes as it is, and so does one with a `:`: that is part of many a script's
    /// name, and only `*` makes Claude's `Bash(…)` rule a prefix rule, which is refused.
    @Test(arguments: ["pnpm typecheck", "pnpm test:unit"])
    func aVerifyCommandPasses(_ verify: String) throws {
        let look = try FixLook(validating: answer(verify: verify), request: request, localOnly: local, agent: .claude)
        guard case .fix(let proposal) = look else { Issue.record("expected a proposal"); return }
        #expect(proposal.verify == verify)
    }

    @Test func refusalsSaySentences() {
        #expect(FixRefusal.unreadableAnswer(.claude).errorDescription == "Claude’s answer was not a plan AiTerm can check.")
        #expect(FixRefusal.branchMovedMeanwhile("feat/x").errorDescription
                == "“feat/x” moved while the fix was being made, so nothing was changed. Try again.")
        #expect(FixRefusal.droppedCommit("feat/x", sha: "abc1234def").errorDescription
                == "The fix would have dropped commit abc1234 from “feat/x” without saying so, so nothing was changed.")
        #expect(FixRefusal.settingsChanged.errorDescription == "The agent changed the copy’s git settings, so its fix was not used.")
        #expect(FixRefusal.movedAfterCheck("feat/x").errorDescription == "“feat/x” moved after AiTerm checked it, so the fix was not used.")
        #expect(FixRefusal.uncheckable(GitError(args: ["status"], code: 128, stderr: "fatal: index file corrupt")).errorDescription
                == "Couldn’t check the fix: Index file corrupt. Nothing was changed.")
    }
}
