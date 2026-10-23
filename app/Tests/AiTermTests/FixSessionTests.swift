import Testing
import Foundation
import Synchronization
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@MainActor struct FixSessionTests {
    let request = FixRequest(title: "t", reason: nil, detail: nil, projectPath: "/p", branch: "feat/x", recreateRebase: true, retry: .createReview)
    let proposal = FixProposal(headline: "h", why: "w", steps: ["s"], moves: ["feat/x"], drops: [], verify: nil)
    let clone = FixClone(path: NSTemporaryDirectory() + "aiterm-fix-test-\(UUID())", branch: "feat/x", startTip: "a", originTip: "b", git: GitRunner())

    /// `prepare` makes the clone's folder — after `slowPrepare`, cut short by a cancel as a real one is not.
    private func pipeline(slowPrepare: Bool = false,
                          look: @escaping @Sendable (FixRequest) async throws(FixRefusal) -> FixLook = { _ in .none("n") },
                          apply: @escaping @Sendable () async throws(FixRefusal) -> Void = {},
                          land: @escaping @Sendable () async -> Void = {}) -> FixPipeline {
        let clone = clone
        return FixPipeline(prepare: { _ in
                               if slowPrepare { try? await Task.sleep(for: .milliseconds(300)) }
                               try? FileManager.default.createDirectory(atPath: clone.path, withIntermediateDirectories: true)
                               return clone
                           },
                           look: { _, _, request throws(FixRefusal) in (try await look(request), "S") },
                           apply: { _, _, _, _ throws(FixRefusal) in try await apply(); return "c" },
                           land: { _, _ in await land(); return FixLanding(branch: "feat/x", old: "a", new: "c") })
    }

    private var cloneExists: Bool { FileManager.default.fileExists(atPath: clone.path) }

    /// Off — Help with problems turned off, or Claude Code missing — offers nothing and does not start.
    @Test func anOffFixerIsUnavailableAndDoesNotStart() async {
        let off = FixSession(request: request, fixer: .off, pipeline: pipeline(), retry: { _ in })
        #expect(off.state == .unavailable)
        off.start(); await off.settled()
        #expect(off.state == .unavailable)
        #expect(!cloneExists)
    }

    @Test func lookThenProposalThenApplyThenDoneAndRetry() async {
        var retried: FixLanding?
        let proposal = proposal
        let session = FixSession(request: request, fixer: .ready(.claude), pipeline: pipeline(look: { _ in .fix(proposal) }), retry: { retried = $0 })
        session.start()
        #expect(session.state == .looking)
        #expect(session.isBusy)
        await session.settled()
        #expect(session.state == .proposal(proposal))
        #expect(session.lastProposal == proposal)
        #expect(session.clonePath == clone.path && cloneExists, "the clone waits for Apply")
        #expect(!session.isBusy)
        session.apply()
        #expect(session.state == .applying)
        #expect(session.isBusy)
        await session.settled()
        #expect(session.state == .done(FixLanding(branch: "feat/x", old: "a", new: "c")))
        #expect(retried?.new == "c")
        #expect(!cloneExists, "the clone goes when the fix is done")
        #expect(session.clonePath == nil)
    }

    /// M4: the action runs again as soon as the fix is in — not after the clone, a whole checkout, is removed.
    @Test func theRetryDoesNotWaitForTheClonesRemoval() async {
        let proposal = proposal, path = clone.path
        var existedAtRetry: Bool?
        let session = FixSession(request: request, fixer: .ready(.claude), pipeline: pipeline(look: { _ in .fix(proposal) }),
                                 retry: { _ in existedAtRetry = FileManager.default.fileExists(atPath: path) })
        session.start(); await session.settled()
        session.apply(); await session.settled()
        #expect(existedAtRetry == true, "the retry started with the clone still there")
        #expect(!cloneExists, "and the clone goes after it")
    }

    /// M5: a landing that finishes as the app quits (`stop()`) — landing itself cannot be cancelled —
    /// is not followed by the retry and its git write.
    @Test func aLandingThatFinishesDuringQuitStartsNoRetry() async {
        let proposal = proposal
        let landing = Mutex(false)
        var retried = false
        let session = FixSession(request: request, fixer: .ready(.claude),
                                 pipeline: pipeline(look: { _ in .fix(proposal) }, land: {
                                     landing.withLock { $0 = true }
                                     try? await Task.sleep(for: .seconds(30))   // cut short by `stop()`, and the landing returned all the same
                                 }), retry: { _ in retried = true })
        session.start(); await session.settled()
        session.apply()
        while !landing.withLock({ $0 }) { await Task.yield() }
        session.stop()
        await session.settled()
        #expect(session.state == .done(FixLanding(branch: "feat/x", old: "a", new: "c")))
        #expect(!retried, "no retry once the app is quitting")
        #expect(!cloneExists, "the clone still goes")
    }

    /// Review focus 4: leaving during Look stops it, removes the clone and goes back to offered.
    @Test func cancellingWhileLookingRemovesTheClone() async {
        let session = FixSession(request: request, fixer: .ready(.claude),
                                 pipeline: pipeline(look: { _ in try? await Task.sleep(for: .seconds(30)); return .none("late") }), retry: { _ in })
        session.start()
        await session.waitForClone()
        #expect(cloneExists)
        session.cancel()
        #expect(session.state == .offered, "at once, not when the agent has gone")
        await session.settled()
        #expect(session.state == .offered, "the late answer is never shown")
        #expect(!cloneExists)
    }

    /// A clone made after the person cancelled is removed as soon as it exists.
    @Test func cancellingWhilePreparingLeavesNoClone() async {
        let session = FixSession(request: request, fixer: .ready(.claude), pipeline: pipeline(slowPrepare: true), retry: { _ in })
        session.start()
        session.cancel()
        await session.settled()
        #expect(session.state == .offered)
        #expect(!cloneExists)
    }

    @Test func cancelOnAProposalDeclinesAndRemovesTheClone() async {
        let proposal = proposal
        let session = FixSession(request: request, fixer: .ready(.claude), pipeline: pipeline(look: { _ in .fix(proposal) }), retry: { _ in })
        session.start(); await session.settled()
        session.cancel()
        #expect(session.state == .offered)
        await session.settled()
        #expect(!cloneExists)
        session.apply()
        #expect(session.state == .offered, "nothing left to apply")
    }

    @Test func cancelDoesNothingWhileApplying() async {
        let proposal = proposal
        let session = FixSession(request: request, fixer: .ready(.claude),
                                 pipeline: pipeline(look: { _ in .fix(proposal) }, apply: { try? await Task.sleep(for: .milliseconds(200)) }), retry: { _ in })
        session.start(); await session.settled()
        session.apply()
        session.cancel()
        #expect(session.state == .applying)
        await session.settled()
        #expect(session.state == .done(FixLanding(branch: "feat/x", old: "a", new: "c")))
    }

    @Test func aRefusedApplyFailsWithItsSentenceAndOffersTryAgain() async {
        let proposal = proposal
        let session = FixSession(request: request, fixer: .ready(.claude),
                                 pipeline: pipeline(look: { _ in .fix(proposal) }, apply: { () throws(FixRefusal) in throw .uncommittedChanges }), retry: { _ in })
        session.start(); await session.settled()
        session.apply(); await session.settled()
        #expect(session.state == .failed(FixRefusal.uncommittedChanges.errorDescription!))
        #expect(!cloneExists, "a refused fix leaves no clone")
        session.tryAgain()
        #expect(session.state == .looking)
        await session.settled()
        #expect(session.state == .proposal(proposal))
    }

    @Test func tryAgainTellsTheNextLookWhyTheLastFixFailed() async {
        let proposal = proposal
        let seen = Mutex<[String?]>([])
        let session = FixSession(request: request, fixer: .ready(.claude),
                                 pipeline: pipeline(look: { request in seen.withLock { $0.append(request.previousFailure) }; return .fix(proposal) },
                                                    apply: { () throws(FixRefusal) in throw .conflictMarkers(["config.ts"]) }), retry: { _ in })
        session.start(); await session.settled()
        session.apply(); await session.settled()
        session.tryAgain(); await session.settled()
        #expect(seen.withLock { $0 } == [nil, FixRefusal.conflictMarkers(["config.ts"]).errorDescription])
    }

    @Test func aFailedLookRemovesTheCloneAndSaysWhy() async {
        let session = FixSession(request: request, fixer: .ready(.codex),
                                 pipeline: pipeline(look: { _ throws(FixRefusal) in throw .unreadableAnswer(.codex) }), retry: { _ in })
        session.start(); await session.settled()
        #expect(session.state == .failed("Codex’s answer was not a plan AiTerm can check."))
        #expect(!cloneExists)
    }

    @Test func noFixShowsTheReasonAndRemovesTheClone() async {
        let session = FixSession(request: request, fixer: .ready(.claude), pipeline: pipeline(look: { _ in .none("A product decision.") }), retry: { _ in })
        session.start(); await session.settled()
        #expect(session.state == .noFix("Claude found no fix it can stand behind: A product decision."))
        #expect(!cloneExists)
        session.start()
        #expect(session.state == .noFix("Claude found no fix it can stand behind: A product decision."), "no second offer for this problem")
    }

    /// A surface that goes away with a proposal up has declined it.
    @Test func aSessionLetGoWithAProposalRemovesItsClone() async {
        let proposal = proposal
        var session: FixSession? = FixSession(request: request, fixer: .ready(.claude), pipeline: pipeline(look: { _ in .fix(proposal) }), retry: { _ in })
        session?.start(); await session?.settled()
        #expect(cloneExists)
        session = nil
        #expect(await eventually(describing: "the clone removed") { !cloneExists })
    }
}
