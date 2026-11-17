import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct SignalClaimTests {
    private func claimed(_ change: (inout AppState, UUID) -> Void = { _, _ in }) throws -> (SignalHarness, SignalClaim) {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let claim = try #require(world.state.signalItem(id: id).flatMap(SignalClaim.init))
        change(&world.state, id)
        return (try SignalHarness(world), claim)
    }

    @Test func aCurrentClaimIsAllowed() throws {
        let (h, claim) = try claimed(); defer { h.cleanUp() }
        #expect(claim.allows(in: h.workspace))
    }

    @Test func aPausedOperatorOrASwitchedOffSignalRefusesTheClaim() throws {
        let (paused, claim) = try claimed { state, _ in state.operatorSession?.paused = true }; defer { paused.cleanUp() }
        #expect(!claim.allows(in: paused.workspace))
        let (off, same) = try claimed { state, _ in state.signals[0].enabled = false }; defer { off.cleanUp() }
        #expect(!same.allows(in: off.workspace))
    }

    @Test func aStoreThatHasNotLoadedRefusesTheClaim() throws {
        var world = SignalWorld(); let signal = world.signal(), id = world.workingTask(signal: signal)
        let claim = try #require(world.state.signalItem(id: id).flatMap(SignalClaim.init))
        let folder = try ScratchFolder.make("aiterm-signal-claim-"); defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = WorkspaceStore(file: StateStore(url: folder.appendingPathComponent("state.json")))
        workspace.mutate { $0 = world.state }
        #expect(claim.holds(in: workspace.state) && !claim.allows(in: workspace))
    }

    @Test func aMovedStageOrOwnershipRefusesTheClaim() throws {
        let (stage, claim) = try claimed { state, id in state.updateSignalTask(id) { $0.stage += 1 } }; defer { stage.cleanUp() }
        #expect(!claim.allows(in: stage.workspace))
        let (owner, same) = try claimed { state, id in state.updateSignalTask(id) { $0.ownership += 1 } }; defer { owner.cleanUp() }
        #expect(!same.allows(in: owner.workspace))
    }

    @Test func anUnknownPhaseRefusesTheClaim() throws {
        let (h, claim) = try claimed { state, id in state.updateSignalTask(id) { $0.phase = .unknown(["kind": "retired"]) } }
        defer { h.cleanUp() }
        #expect(claim.holds(in: h.workspace.state) && !claim.allows(in: h.workspace))
    }

    @Test func aCancelledTaskIsRefusedTheClaim() async throws {
        let (h, claim) = try claimed(); defer { h.cleanUp() }
        let workspace = h.workspace
        let inside = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return claim.allows(in: workspace)
        }
        #expect(await inside.value == false)
        #expect(claim.allows(in: workspace))
    }
}
