import Foundation
import Observation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTerm

@MainActor
struct PerRowTests {
    private func workspace(terminals: [UUID]) -> WorkspaceStore {
        let store = WorkspaceStore(file: StateStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")))
        store.mutate { state in
            state.terminals = terminals.map { TerminalItem(id: $0, projectId: UUID(), name: "Shell", windowId: nil, createdAt: Date()) }
        }
        return store
    }

    @Test func aWriteRedrawsOnlyTheRowWhoseValueItChanges() {
        let rows = PerRow(default: false, workspace: workspace(terminals: []))
        let a = UUID(), b = UUID()
        #expect(!invalidates({ _ = rows[a] }, by: { rows[b] = true }))
        #expect(invalidates({ _ = rows[a] }, by: { rows[a] = true }))
        #expect(!invalidates({ _ = rows[a] }, by: { rows[a] = true }), "an equal write redraws nothing")
        #expect(rows[a] && rows[b])
    }

    /// A cell goes once its row has left the workspace and holds the default; a cell still holding
    /// something stays, so a row that comes back reads what its owner says.
    @Test func aCellGoesWithItsRowOnceItHoldsTheDefault() {
        let kept = UUID(), gone = UUID(), held = UUID()
        let workspace = workspace(terminals: [kept])
        let rows = PerRow(default: false, workspace: workspace)
        rows[held] = true
        let keptRead = Mutex(false), goneRead = Mutex(false)
        withObservationTracking { _ = rows[kept] } onChange: { keptRead.withLock { $0 = true } }
        withObservationTracking { _ = rows[gone] } onChange: { goneRead.withLock { $0 = true } }

        workspace.mutate { $0.terminals.append(TerminalItem(id: UUID(), projectId: UUID(), name: "Other", windowId: nil, createdAt: Date())) }
        rows[kept] = true
        rows[gone] = true

        #expect(keptRead.withLock { $0 }, "a row still in the workspace keeps its cell")
        #expect(!goneRead.withLock { $0 }, "a gone row's cell was dropped, so the write made a new one")
        #expect(rows[held], "a cell holding a value outlives its row until the owner clears it")
        #expect(rows[gone])
    }
}
